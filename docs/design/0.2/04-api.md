# S4 Public API and user contract

Normative for DispatchCheckup 0.2.0. "Must", "should" and "may" are used as in RFC 2119. This section covers what users write, see and can rely on. The mechanisms behind it are specified in other sections: wrapper template (O4), image and depot (D04, D13, D17/D47, D24, D45, D46), records and audit (D05, D44), and descendants (D12).

Evidence paths are relative to `$AUDIT`, the maintainer's local review archive (not part of this repository; defined in the S1 conventions).

**Terms**

| Term | Meaning |
|---|---|
| target | The package named in the activation call. |
| activating file | `Base.source_path(nothing)` at the call. |
| activating process | The process in which the first call activated. |
| run member | The activating process, or a descendant that joined its run (D12). |
| guard child | The single fresh process that runs the `original=` files. |
| owned module | The target's root module, its submodules and its extension modules. |
| private depot | `<DEPOT_PATH[1]>/compiled/v1.13/.dispatchcheckup/`, or `DISPATCH_CHECKUP_DEPOT` when set. |
| walked source | The syntactic index of every file reached by literal `include` from the target's entry file (`src/<Name>.jl`, or its `entryfile`) and from each `[extensions]` entry. It includes extensions that are not loaded and branches that are never taken (D10). |

---

## Quick start (user section)

Add DispatchCheckup as a test dependency. It is not registered in 0.2, so it is tracked from `main`:

```toml
[extras]
DispatchCheckup = "ca055ede-32eb-4961-937e-82d9c5ec6430"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["DispatchCheckup", "Test"]

[compat]
DispatchCheckup = "0.2"      # keeps Aqua's deps_compat check green with the lines commented out
julia = "1.13"

[sources]
DispatchCheckup = {url = "https://github.com/AzamatB/DispatchCheckup.jl", rev = "main"}
```

Put the call at the top of `test/runtests.jl`, before anything loads `MyPackage`:

```julia
import DispatchCheckup
DispatchCheckup.dispatch_doctor(:MyPackage; unstable = (:foo, :bar), original = ("test_guards.jl",))

using Test, MyPackage
include("test_core.jl")
get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("test_guards.jl")
```

- **Run.** `julia --project -e 'using Pkg; Pkg.test()'`. The suite runs once, against instrumented `MyPackage`. Then `test_guards.jl` runs once in a fresh process against the original code.
  - The process exits nonzero if the suite fails, if any checked call was type-unstable, or if a guard fails.
  - The summary and the report path are printed at the end.
- **Turn it off.** Comment out the two lines; the run is then as if DispatchCheckup did not exist (D51), and `test_guards.jl` is included normally.
  - If the call spans several lines, comment out all of them. Constants that only the call uses may stay.
- **CI.** Gate the two lines and add one checkup job (D40).
- **What a pass means.** Every definition DispatchCheckup wrapped and the tests called returned a concrete inferred type for the signatures the tests exercised, or a `Union` within `union_limit`.
  - With `require_all=true`, it also means that nothing in the package escaped classification (D11).
  - It is not runtime coverage, JET or allocation checking. Keep those checks in guards.
- **Placement.** Put platform and hardware skips that `exit()` before the activation lines. A run that never loads the target fails with "nothing was checked".

---

## D29 Activation call

**Decision.** The whole public API is one function:

```julia
DispatchCheckup.dispatch_doctor(pkg::Symbol; unstable = (), original = (), union_limit = 1,
                                require_all = false, mode = :record, report = nothing) -> nothing
```

**Requirements**

- **Public surface**
  - `dispatch_doctor` is the only public name. It is declared `public dispatch_doctor` and is not exported.
  - DispatchCheckup defines no other public function, macro or type. Error mode throws DispatchDoctor's (DD's) own `TypeInstabilityError`.
- **Keywords**
  - The call has exactly these six keywords. There is no `exclude=`, `allow=`, `waive=`, `macros=`, `entrypoint=` or `share_assets=`.
  - An unknown keyword must stay Julia's own `MethodError`, which lists the valid keywords. So there is no `kwargs...` catch-all.
  - Keywords carry no type annotations. Each one is validated by hand. An invalid value throws `ArgumentError("dispatch_doctor: <keyword> = <repr>: <accepted forms>")`, because a `::Bool` annotation's error does not name the keyword.
- **Wrong package argument.** Extra methods `dispatch_doctor(::Module; kw...)` and `dispatch_doctor(::AbstractString; kw...)` throw an `ArgumentError` with the Symbol spelling. For a Module, the message adds "call it before the package is loaded".
- **Validation and return**
  - All argument validation is pure and finishes before any side effect.
  - The call returns `nothing`.
- **Normalised options.** The normalised option set is canonical and hashable. It drives repeat-call comparison (state machine below) and the D45 compile-time table.
  - `unstable`: canonical spellings, sorted and deduplicated. An entry's canonical spelling is the text the report prints for it, re-printed from its parsed form (D10 Parsing):
    - a bare name as `repr(name)`, for example `:foo` or `:(==)`;
    - a qualified name as `Symbol("A.B.c")`, whose last component is written `:op` for an operator and `var"…"` when it is not an identifier;
    - a site as `:name => "path:LINE"`, with `/` separators.

    Entries with equal spellings are duplicates. Sorting is by spelling.
  - `original`: realpaths in order, deduplicated (first kept).
  - `report`: an absolute path, `:default` or `false`.
  - `union_limit::Int`, `require_all::Bool`, `mode::Symbol`.
- **List keywords**
  - `unstable` and `original` accept any iterable, collected once.
  - A lone `Symbol` or `Pair` is one `unstable` item, and a lone `AbstractString` is one `original` item. So `unstable = (:foo)`, which is a Symbol, and `original = "g.jl"` behave as one-element lists.
- **Docstring.** It lists every keyword with its default and its compile-time or runtime class.

**Keywords**

| keyword | accepted | default | class (D45) | semantics |
|---|---|---|---|---|
| `unstable` | iterable of entries (grammar in D10); a lone `Symbol` or `Pair` | `()` | compile-time | Listed definitions are **not wrapped and not checked** by DispatchCheckup, as with DD's `@unstable`: production code runs. A listed definition that carries its own explicit source `@stable` therefore keeps DD's native check, as in production; a listed member of a source `@stable` block is emitted unwrapped (D10). Listing a definition DispatchCheckup cannot check acknowledges it for `require_all`. This is the only selection list. |
| `original` | iterable of path strings; a lone string | `()` | runtime | Standalone guard files that run once after the suite, in one fresh ordinary process, against the original code (D02). |
| `union_limit` | `Integer >= 1`, not `Bool` | `1` | compile-time | Applies to wrappers DispatchCheckup generates. A return type that is a `Union` of at most `union_limit` concrete types passes. Source `@stable` annotations keep their production limit (below). |
| `require_all` | `Bool` | `false` | runtime | Fails the run if any blind spot is not listed in `unstable=` (D11). DD limitations are reported with locations and counts, never counted. |
| `mode` | `:record` or `:error` | `:record` | runtime | `:record` runs the real body, records every instability and fails at the end with the full list. `:error` throws `TypeInstabilityError` at the call; it is for debugging only. |
| `report` | `nothing`, a string path ending in `.toml`, or `false` | `nothing` | runtime | `nothing` writes the default file in the private depot and prints its path at the end. A path is resolved against the activating file (D15). `false` writes no file. |

- "Compile-time" means the value is part of the instrumented image key.
  - Changing it rebuilds the target image, plus its extensions and the dependents keyed by the D46 hook, once, at activation. After activation, the target and its extensions are never built; dependents may be built lazily (D51 "Builds after activation").
  - Reverting to an earlier value reuses the image built for it. Base keeps at most 10 images per package (D45).
  - Reordering `unstable` does not rebuild, because entries are canonicalised.
- "Runtime" values never trigger a rebuild.

**`union_limit` and source annotations (D09)**

- The effective limit of a source `@stable` annotation (single or block) is its production one:
  - the target's `dispatch_doctor_union_limit` preference;
  - otherwise the annotation's `default_union_limit`;
  - otherwise 1.
- That preference does not change the limit of DispatchCheckup-generated wrappers.
- `mode=` overrides the mode of source annotations: they record or throw like every other check. Tests that assert DD's own behaviour, such as `@test_throws TypeInstabilityError` on source-annotated code, belong in `original=`.
- The report prints each effective limit with its origin.

**`mode` details (D03, conflicts 4 and 5)**

- `mode` is read at runtime from the run configuration, so one image serves both modes.
- In `:record` mode the recorder:
  - never logs or prints during the suite;
  - deduplicates by site and signature;
  - runs the original body.
- In pure contexts (generators), neither mode throws. The event is recorded with `context = "generator"` and counts like any other instability.
- Processes that are generating output (precompile workers) neither record instabilities nor throw. Their evaluation-time definition records go into the image (D05).
- Tests must never assert that a check DispatchCheckup inserted throws. Such a test fails with the lines commented out.

**Rationale**

- Design A makes this call the user contract, and a config object or file would add more to comment out.
- Verified facts:
  - An unknown keyword gives a `MethodError` that lists the valid keywords.
  - A `::Bool` annotation's error does not name the keyword.
  - `(:foo)` is a `Symbol`, and a `String` iterates as `Char`s.
  - Installed package trees are read-only, so the default report must not go in the package tree. Evidence: $AUDIT/devil-D29-api-surface-w8n3/sp.

**Tests**

- Contract: `Base.kwarg_decl(only(methods(dispatch_doctor, (Symbol,))))` equals the documented list, in order.
- Every invalid value of each keyword throws an `ArgumentError` naming the keyword, and afterwards `ENV`, `LOAD_PATH`, `DEPOT_PATH` and the atexit hook count are unchanged.
- These each count as one item: `unstable = :foo`, `unstable = (:foo)`, `unstable = :foo => "src/a.jl:3"` and `original = "g.jl"`. `unstable = keys((a = "x", b = "y"))` is accepted.
- A Module or String package argument gives the hint. The call returns `nothing`.

---

## D15 Path resolution

**Decision.** There is no entry discovery and nothing is re-run. Relative `original=` and `report=` paths are resolved once, at activation:

- against `dirname(Base.source_path(nothing))`;
- against `pwd()` when that is `nothing`: under `-e`, stdin, or a spawned task.

**Requirements**

- **Resolution**
  - The stored path is absolute: `normpath(joinpath(base, p))`. A later `cd()` does not change it.
  - `original=` entries must exist when the call is made. They are compared by realpath and deduplicated, and the activating file itself is rejected.
- **Reporting.** The banner and the report print the base and its kind (`activating_file` or `pwd`).
- **Guard child.** It runs in the `pwd()` that was current at activation. Under `Pkg.test` that is `test/`.
- **Compat module.** `Base.source_path` and `Base.include_callbacks` are internal, so they sit behind the compat module, with a smoke test.

**Rationale**

- `source_path` inside the call returns the innermost included file.
- Under `Pkg.test`, `pwd()` and the activating file's directory agree.
- `julia test/runtests.jl` run from the repo root now resolves against `test/`. 0.1 resolved against the cwd.
- Spawned tasks lose `SOURCE_PATH`; the existence check catches this.
- `Base.source_path()` returns `""` on 1.13.2 and `source_path(nothing)` returns `nothing` (checked).
- Evidence: $AUDIT/D15-entry-discovery-r8t5/sp and /proto.

**Tests**

- Direct run from the repo root, `Pkg.test`, and `-e 'include("test/runtests.jl")'`.
- Activation from an included helper: the base is the helper's directory.
- Activation inside `@async` with a relative `original=` throws "not found", naming the `pwd` base.

---

## D10 `unstable=`: grammar, matching, validation

**Decision.** `unstable=` follows DispatchDoctor (DD) `@unstable` semantics: every matched definition is emitted exactly as production code, with no DispatchCheckup wrapper and no DispatchCheckup check. Matching is syntactic and decided when the definition is emitted. Validation happens in three stages.

**Grammar** (closed: anything else is an `ArgumentError` with a suggested spelling)

| form | example | meaning |
|---|---|---|
| (a) bare name | `:foo`, `:(==)`, `:..`, `:pop!` | Every checkable definition whose **written final name** is `foo`, in any owned module (root, submodules, extensions). The written qualifier does not matter: `foo(...)`, `Base.foo(...)` and `Dep.foo(...)` all match. |
| (b) owned-qualified | `Symbol("MyPackage.Sub.foo")`, `Symbol("MyPackageSomeExt.foo")` | Definitions **evaluated in exactly that module**. The first component is the target or one of its `[extensions]` names. `Symbol("MyPackage.foo")` means the root module only. |
| (c) foreign-qualified | `Symbol("Base.getindex")`, `Symbol("Core.Array")`, `Symbol("SomeGPUPkg.GPUArray")` | Definitions in owned modules whose callee is **spelled** that way, or whose callee **resolves at emission time** to that foreign function or type. The owner is `join(fullname(parentmodule(f)), ".") * "." * nameof(f)`. For a type, `parentmodule` is taken of `Base.unwrap_unionall(T)` when that is a `DataType`; otherwise only the spelling counts (#54). |
| (d) site | `:foo => "src/file.jl:LINE"` | The definition(s) with written final name `foo` whose **own first line** is `LINE`. `LINE` is the line DD prints after "defined at", and equals `Method.line`. The path is relative to the package root, uses `/`, is never absolute and has no `..`. The key must be a bare name, because the site already fixes the module. |

**Parsing**

- A Symbol that `Base.isidentifier` or `Base.isoperator` accepts is a bare name, so `:..`, `:.+` and `:(==)` stay atomic.
- Anything else is parsed with `Meta.parse`. It must yield a dotted chain of names whose last part may be a quoted operator or a `var"..."`: `Base.:+`, `MyPackage.:..`, `MyPackage.var"x y"`.
- Rejected inputs, each with a hint:
  - `Symbol("MyPackage...")` parses to a splat; the suggested spelling is `Symbol("MyPackage.:..")`.
  - String entries are rejected.
  - Entries from iterating a `Dict` or `NamedTuple` of justifications (values or Pairs with prose): the hint says "pass `keys(...)`".

**Matching rules**

- **Exclusions** (a) through (d) unwrap every matching definition, inner constructors included (D08).
- **Source `@stable` under `unstable=` (Resolved (default)).** DD's `@unstable` is a no-op that only hides code from implicit wrapping; an explicit author-written `@stable` still applies in production. So:
  - a matched definition that carries its own explicit source `@stable` keeps that annotation, and DD's native check stays, as in production;
  - a matched member of a source `@stable` block is emitted unwrapped (S3.10).
- **Blind spots**: an entry may match a definition that DispatchCheckup cannot check:
  - an unvetted decorator (D06);
  - a definition produced by an opaque macro (D07);
  - a method found by the audit (D44).
  The entry then marks it **acknowledged** for `require_all`.
- **By-design skips and limitations**:
  - By-design skips (D08): `__init__`, methods DD ignores, `@nospecialize` methods, modules with inference disabled, PrecompileTools workload bodies.
  - DD limitations: curly-named constructors, callable objects, `@generated`.
  An entry whose only matches are these is **redundant**. It is reported, not an error, so the 0.1 `unstable = (:__init__,)` workaround keeps working.
- **Source regions.** A source `@unstable` region acts like listing its contents, and the report shows its origin as "source @unstable" (D07, D09).
- **Evaluation-time records.** Matches count only from evaluation-time records (D05), merged from all run members (D12), plus, for blind spots, the named methods the D44 audit reports. Definitions in dead branches, in extensions that were not loaded, or in `@testitem` bodies never match.
- **Candidates**
  - Every definition site the walker records is a candidate, whatever its kind.
  - Names that appear only in quoted code, in nested closures, or in bodies of test-only macros (the `@testitem` family) are not candidates. The error message says where the name was seen.

**Validation**

1. **At activation**, from walked source, before any image is built (0.26 s for Makie's 151 files):
   - A malformed entry is an `ArgumentError`.
   - An entry of form (a)–(c) with **no candidate** is an error listing up to 5 nearest names, by edit distance over the index. For form (c), a candidate is any owned definition whose written final name equals the entry's last component, because resolution happens only at emission (S3.10).
   - A form (b) entry naming no owned module is an error listing the owned modules and extensions.
   - A form (d) entry whose file is not in walked source is an error. So is one whose file has no definition with that name starting at `LINE`; the message lists that name's definitions in the file with their current first lines.
   - Exception: if the walker met an `include` whose path it cannot resolve statically, a non-literal top-level `eval`, or an opaque macro with no visible definitions (S3.8), zero-candidate entries are deferred to stage 3 instead, where the audit's named blind spots can match them (D11, D44), and the banner says so.
2. **After load.** Entries are classified from the evaluation-time records of the target and each loaded extension. Nothing is printed during the suite (D22).
3. **At exit**, after merging descendant records and extensions loaded mid-suite, every entry has exactly one state:
   - `matched`, with count and sites;
   - `redundant`;
   - `inactive`, with a reason, when all its candidates are in code not evaluated this run (an extension not loaded, a false `@static` or `if` branch, a conditional include). This is reported, not an error.
   - A deferred entry that still matched nothing is an error, and it fails validation. So is an entry whose candidates were all evaluated but none matched (for example a form (c) callee that resolved to another owner); the message lists each candidate and what it resolved to.

   A bare entry that matched definitions in more than one module, or of more than one generic function, gets a **note** in the summary and the report suggesting a qualified or site entry (conflict 20).

**Examples** (generalised from the internal consumer repositories; package, module and file names are placeholders)

| entry | form | matches |
|---|---|---|
| `:_helper` | (a) | Every `_helper` in MyPackage, its submodules and its extensions. |
| `Symbol("MyPackageSomeExt.helper")` | (b), extension | `function helper()` at ext/MyPackageSomeExt.jl:45. It is **inactive**, not an error, on legs where the extension's trigger package is not loaded. |
| `Symbol("MyPackage.Sub.Thing")` | (b), submodule | Constructors written `Thing(...)` evaluated in `MyPackage.Sub` (src/sub/thing.jl:20 and any inner constructors), not in the root module. A curly `Thing{N}(...)` is a DD limitation, so it is redundant. |
| `Symbol("Base.getindex")` | (c) | `function Base.getindex(t::Table, key::AbstractString)` at src/table.jl:60, matched by spelling. Also any owned `getindex` that extends `Base.getindex` through `import`, matched by resolution. |
| `Symbol("Core.Array")` | (c) | `Base.Array(v::DeviceVector) = to_host(v)` at src/vector.jl:30, matched by resolution because `Array` is owned by `Core`. `Symbol("Base.Array")` matches the same definition by spelling. |
| `Symbol("SomeGPUPkg.GPUArray")` | (c) | `SomeGPU.GPUArray(v::DeviceVector)` at src/vector.jl:31, matched by resolution: the callee is written through the front-end package `SomeGPU`, but `GPUArray` is defined in the package `SomeGPUPkg`. |
| `keys(UNSTABLE_REASONS)` | list | A `NamedTuple` mapping names to justification strings (68 in one internal consumer). `keys` gives a `Tuple` of bare names, and each name is validated separately. |
| `:_lookup => "src/lookup.jl:57"` | (d) | One definition: the one whose first line is 57. |

**Messages**

```
ERROR: ArgumentError: dispatch_doctor: unstable entry :solv! matches no definition in MyPackage's source.
Nearest: :solve! (src/solve.jl:41, src/krylov/gmres.jl:12), :solver (src/types.jl:8).

ERROR: ArgumentError: dispatch_doctor: unstable entry :helper => "ext/MyPackageSomeExt.jl:43":
no definition of helper starts at line 43. Definitions of helper in that file start at: 45.

ERROR: ArgumentError: dispatch_doctor: unstable entry Symbol("MyPackage.Nestd.foo"): MyPackage has no module Nestd.
Owned modules: MyPackage, MyPackage.Nested; extensions: MyPackageCUDAExt.

ERROR: ArgumentError: dispatch_doctor: unstable entry Symbol("MyPackage...") is not a name; write Symbol("MyPackage.:..").

ERROR: ArgumentError: dispatch_doctor: unstable entry "foo" is a String; entries are Symbols (:foo) or
Pairs (:foo => "src/file.jl:LINE"). To list the names of a NamedTuple or Dict of reasons, pass keys(...).
```

Summary lines:

```
unstable=  Symbol("MyPackageSomeExt.helper"): inactive (extension MyPackageSomeExt not loaded)
unstable=  :__init__: redundant (__init__ is never checked)
note       :solve! matched definitions in MyPackage and MyPackage.Krylov; use Symbol("MyPackage.solve!") or a site entry to narrow it
```

**Rationale**

- Unwrapping is decided at emission, so `unstable=` really is an escape hatch. Syntax is the only load-order-independent basis available at emission.
- Resolving against a partly loaded module caused #6, #24 and #48.
- Foreign resolution is safe because foreign modules are complete when the definition is emitted (#53).
- Index cost: Makie 0.26 s ($AUDIT/D10-exclusion-semantics-p3v9/index_cost.jl).
- DD's line equals `Method.line` (lines.jl).
- Bare `path:line` selectors silently retarget: 6 of 21 OrderedCollections sites moved between releases. So site entries carry the name (D48).

**Tests**

- A grammar table, including `:..`, `Base.:+`, `MyPackage.var"x y"` and each rejection.
- One fixture per example above.
- A listed definition with its own explicit source `@stable` keeps DD's native check; a listed member of a source `@stable` block is emitted unwrapped.
- Dead branch and unloaded extension give `inactive`; an `@testitem`-only helper is an error; `:__init__` is `redundant`; a bare key in two modules gets the note.
- The stage-1 typo error is raised before any write to the private depot.
- Deferral when an include is computed.
- A match that occurs only in a descendant counts.
- A reordered `unstable` reuses the image.

---

## D11 `require_all` (user view)

**Decision.** With `require_all=true` the run fails at exit if any **blind spot** is not listed in `unstable=`. With `false`, blind spots are only reported. **Resolved (default):** this is D11's reading of O6's "code that could not be checked". Only blind spots not listed in `unstable=` are counted. DD limitations are deterministic; they are reported with their locations and counts, and never counted (open point 8).

**Requirements**

- Blind spots are the only thing counted:
  - definitions under decorators that are not in the vetted table (D06);
  - definitions produced by opaque method-defining macros (D07);
  - top-level `eval` of code that is not a literal;
  - owned methods that the method-table audit finds and that no record accounts for (D44).
- Never counted (all are reported):
  - DispatchDoctor (DD) limitations, with their locations and counts per reason;
  - by-design skips;
  - nested closures (informational).
- Literal `@eval` bodies are instrumented, so they are not blind spots.
- The summary prints a copy-pasteable `unstable = (...)` with site entries for every unacknowledged blind spot.
- The README describes the guarantee as "nothing escaped classification", not "everything was checked".

**Rationale.** Counting DD's deterministic limitations made `require_all` unusable: StaticArrays would need about 207 gaps waived, against near zero for the blind-spot model ($AUDIT/D11-require-all-k4w9).

**Tests**

- An unvetted decorator fails, and passes once listed.
- An `@generated` function does not fail.
- An audit-found `@eval $ex` method fails, and passes once listed by name.

**Non-literal `eval` sites. Resolved (default).** A non-literal `eval` site has no written name, so it can be acknowledged only through the audited methods it defines. This spec counts those methods by name and line, and treats an eval site that defines no owned method as informational. The coverage section (D44) implements this.

---

## D14 Interactive sessions

**Decision.** DispatchCheckup refuses to activate in a session that outlives the run. It throws an ordinary error before any side effect, so the `include` unwinds and the session survives.

**Requirements**

- **Condition:** `isinteractive() || isdefined(Main, :PlutoRunner) || isdefined(Main, :VSCodeServer) || isdefined(Main, :IJulia)`.
- **Not refused:**
  - piped stdin without `-i`;
  - a `Pkg.test` subprocess started from a REPL;
  - the VS Code debugger;
  - VS Code test items, which never run `runtests.jl`.
- **Escape hatch.** There is no pass-through mode and no override.
- **Message.** The host name is one of REPL, Pluto notebook, VS Code, or IJulia. The command and paths are filled in:

```
ERROR: dispatch_doctor(:MyPackage) refuses to run in an interactive session (REPL). Nothing was changed.
A checked run redirects MyPackage for the rest of the process and reports when the process exits,
so this session would never show the verdict. Run the checked suite in a fresh process instead:
  from this session:  using Pkg; withenv(() -> Pkg.test("MyPackage"), "DISPATCH_CHECKUP" => "on")
  or:                 run(addenv(`/opt/julia-1.13.2/bin/julia --project=/work/MyPackage/test /work/MyPackage/test/runtests.jl`, "DISPATCH_CHECKUP" => "on"))
To include this file interactively without checks, gate the two DispatchCheckup lines on DISPATCH_CHECKUP
(see "CI gate" in the README) or comment them out.
```

**Rationale**

- Julia cannot unload the overlay.
- `"checked"` would leak into later `]test` runs from the same session.
- In record mode the verdict exists only at exit.
- Pluto workers and VS Code notebook kernels report `isinteractive() == false` ($AUDIT/D14-interactive-repl-m4v8).

**Tests**

- `printf 'include("runtests.jl")\nprintln(isdefined(Main,:MyPackage))\n' | julia -i`: the refusal text appears, the session continues, and the target, `ENV`, `LOAD_PATH`, `DEPOT_PATH` and the atexit hooks are unchanged.
- `Pkg.test()` run from `julia -i` completes a checked run.
- A stub `Main.PlutoRunner` is refused.
- Piped stdin without `-i` is not refused.

---

## D29 / D31 / D49 Activation state machine

**Decision.** Each call classifies its process by the checks below, in order. The first step that applies decides the outcome. Nothing is mutated before ACTIVATE or JOIN begins. Every refusal or failure that is not shown as `ArgumentError` is an `ErrorException` thrown with `error(msg)`, because DispatchCheckup defines no exception type (D29). Its text is the one under **Messages**.

1. **Validate arguments** (pure). Failure is an `ArgumentError`.
2. **Guard child.** If `DISPATCH_CHECKUP_RUN` starts with `guard:` (the marker `guard:<pid>`), the call is **inert**: it returns `nothing` and prints nothing. This applies in the guard child and in all its descendants, so a shared `setup.jl` that contains the activation lines works (Resolved (default); D31 gives the guard child's ENV).
3. **Interactive host**: refuse (D14).
4. **Generating output** (`jl_generating_output() == 1`): error, "dispatch_doctor must be called from a test script, not while precompiling".
5. **Window** (O14). Each failure is fail-closed:
   - Julia is outside `[1.13.0, 1.14.0-)`;
   - `pkgversion(DispatchDoctor) < v"0.4.29"`;
   - `DispatchDoctor.JULIA_OK` is false;
   - `pkgversion(MacroTools) < v"0.5.12"` (the floor measured in D20; Resolved (default): adopted in addition to the DispatchDoctor floor, and re-measured after the walker refactor, D01 P2);
   - the DispatchDoctor runtime-helper self-test fails (S3.2; S2 D16);
   - the OS is not Linux, macOS or Windows (S5 D25; Resolved (default): activation fails closed on every other operating system).
6. **This process already called** (in-memory state):
   - A different target is the D49 error.
   - The same target with equal normalised options is a **no-op**.
   - The same target with different options is an `ArgumentError`. It names the first differing keyword, both values, and the file and line of the first call.
7. **Environment.** Let `v = DISPATCH_CHECKUP` and `r = DISPATCH_CHECKUP_RUN`.
   - `v` not in {unset, `""`, `"on"`, `"checked"`: error, with the YAML hint for `"true"`, `"yes"` or `"1"`.
   - `v == "checked"` and `r` names a live run (state file present, owner pid alive, run not closed):
     - same target UUID: **JOIN**;
     - other target: the D49 error.
   - `v == "checked"` and `r` missing, invalid or dead: the inherited-state error.
   - `v` unset, `""` or `"on"` with a non-guard `r` set: error, "DISPATCH_CHECKUP_RUN is private; clear it, JULIA_LOAD_PATH and JULIA_DEPOT_PATH to start an independent run".
   - Otherwise the run is **FRESH**.
8. **FRESH preconditions**. All are checked before any mutation:
   - **Target**
     - The target can be identified from the active project, as a direct dependency or as the project itself. Otherwise error, with did-you-mean.
     - It is not in DispatchCheckup's load closure: DispatchCheckup, DispatchDoctor, MacroTools, Preferences, TOML, Dates, Printf (#40).
     - It is not loaded yet.
   - **Workers.** No Distributed workers exist yet (`julia -p` or `--machine-file`).
   - **Options**
     - `unstable=` passes stage 1.
     - Every `original=` file exists.
     - An explicit `report=` path has an existing directory and is not itself a directory. Its `.toml` suffix is a value check, an `ArgumentError` at step 1. Writability is settled by the placeholder write at ACTIVATE step 3. A failure there rolls back and raises the same error (F-09).
     - `DISPATCH_CHECKUP_DEPOT`, when set and non-empty, is an absolute path (S2 D17+D47).
9. **ACTIVATE**, in this order:
   This is the observable summary of S2 D30's ACTIVATE mechanics, in the same order:
   1. Snapshot ENV, LOAD_PATH, DEPOT_PATH, DL_LOAD_PATH, the active project, `pwd()`, ARGS, the flags and the activating file (S2 D18).
   2. Prepare the private depot (key check, GC, overlay) and derive the environment (S2 D17+D47, D13, D24).
   3. Create the run directory, write the report placeholder and set `DISPATCH_CHECKUP_RUN`.
   4. Pin the active project and prepend the environment to `LOAD_PATH`. Build or reuse the images with the private depot first on `DEPOT_PATH`, then put it last (D04, D17). This eager precompile captures its output. At run time the user depot stays `DEPOT_PATH[1]`.
   5. Install the include-leak callback (D02) and the load-identity callback (D16).
   6. Export the redirect (D12).
   7. Call `Base.exit_on_sigint(true)` (D50). Register exactly two atexit hooks (Resolved (default)): first the D50 reaper hook, then the single finalizer hook that validates, writes the report, runs the guards and sets the exit status (D30, D50). The reaper only kills a guard child that is still alive after a signal.
   8. Set `DISPATCH_CHECKUP = "checked"`, last.
   9. Print the banner.

   If any of these steps fails, the call restores the snapshot, disarms the hooks and rethrows. A failed call leaves no state outside the private depot, apart from its run directory (removed at exit) and an explicit `report=` file marked `failed` (S2 D30 rollback).

**JOIN (descendant)**

- **Options**
  - Compile-time options (`unstable`, `union_limit`) must equal the run's. If they differ, the call errors and names both values (conflict 18).
  - Runtime-only options (`original`, `report`, `require_all`, `mode`) are ignored. A note goes to the descendant's record file and appears in the parent's summary.
- **Redirect.** If the redirect is missing, for example after a nested `Pkg.test` reset `JULIA_LOAD_PATH` or after `Pkg.activate`, it is prepended again (D12). This applies only when the target has not been loaded yet; otherwise it is the "already loaded" error.
- **Output.** A joined process records into the run but prints nothing and runs no guards, verdict or report.

**Process kinds**

| process | recognised by | activation call |
|---|---|---|
| ordinary run, lines commented out | — | not reached |
| ordinary run, gate closed | `DISPATCH_CHECKUP` unset or `""` | not reached |
| fresh checked run | `v` ∈ {unset, `""`, `"on"`}, no `r` | ACTIVATE |
| same process, repeated call | in-memory state | no-op or error |
| Distributed, ReTestItems, Malt/ParallelTestRunner worker, `run(julia ...)` | `v == "checked"`, live `r`, same target | JOIN |
| monorepo leaf suite under a checked root | live `r`, other target | D49 error |
| guard child and its descendants | `r = "guard:<pid>"` | inert |
| precompile worker | `jl_generating_output` | error |
| REPL or notebook | D14 condition | refused |
| hand-set or stale `"checked"` | `r` missing or dead | error |

**Messages**

```
ERROR: DispatchCheckup checks one package per test process: this run already checks MyPackageCore
(activated at test/runtests.jl:2), so dispatch_doctor(:MyPackage) cannot add a second target.
Use one checked run per package (a separate CI step or Pkg.test per package). The target need not be the
package under test, but it must be a direct dependency of the active project. If a root suite runs leaf
suites that carry their own activation lines, gate the root's lines on DISPATCH_CHECKUP.

ERROR: DispatchCheckup: MyPackage is already loaded, so it can no longer be instrumented. Call dispatch_doctor
before `using MyPackage` (the two lines go at the top of test/runtests.jl). If they are there, MyPackage was
loaded earlier by startup.jl, Revise, -L/-e code, or a package loaded before the call that depends on it.

ERROR: DispatchCheckup: DISPATCH_CHECKUP is "checked" but this process is not part of a live checked run
(DISPATCH_CHECKUP_RUN is missing or its run has ended). "checked" is set only by DispatchCheckup; it was
inherited from a finished run or set by hand. Set DISPATCH_CHECKUP=on (or unset it) to start a checked run.
To start an independent run from a checked suite, clear DISPATCH_CHECKUP, DISPATCH_CHECKUP_RUN,
JULIA_LOAD_PATH and JULIA_DEPOT_PATH in the spawned command.

ERROR: DispatchCheckup: DISPATCH_CHECKUP="true" is not valid. Set DISPATCH_CHECKUP=on to request a checked run,
or unset it (or set it to "") to run without checks. "true" usually comes from an unquoted YAML
`DISPATCH_CHECKUP: on`; write `DISPATCH_CHECKUP: "on"`.

ERROR: DispatchCheckup 0.2 checks only on Julia 1.13.x; this is Julia 1.14.0. Nothing was changed.
Run the checked job on Julia 1.13 and leave DISPATCH_CHECKUP unset on other legs.

ERROR: DispatchCheckup 0.2 needs DispatchDoctor >= 0.4.29 in the test environment; found 0.4.25. Nothing was
changed. Update it (Pkg.update("DispatchDoctor")); ordinary runs are unaffected.

ERROR: DispatchCheckup: 2 Distributed workers already exist (julia -p / --machine-file). They started before
the redirect and would run unchecked code. Start workers with addprocs after dispatch_doctor.

ERROR: DispatchCheckup cannot check Preferences: DispatchCheckup itself loads it
(DispatchCheckup, DispatchDoctor, MacroTools, Preferences, TOML, Dates, Printf).

ERROR: ArgumentError: dispatch_doctor(:MyPackage) was already called at test/runtests.jl:2 with
union_limit = 1; this call (test/setup.jl:5) passes union_limit = 2. Repeated calls must pass identical options.

ERROR: DispatchCheckup: this process joins the checked run of MyPackage (pid 41213), whose image was built
with unstable = (:foo,); this call passes unstable = (:bar, :foo). A descendant cannot change unstable= or
union_limit=. Compute them the same way in every process.
```

The load-identity check (D16) runs in a package callback. Base catches exceptions there, so the callback exits instead of throwing:

```
DispatchCheckup: MyPackage was loaded from /Users/u/.julia/compiled/v1.13/MyPackage/AbCd1_xyz.ji, not from the
instrumented image. Likely causes: Pkg.activate or TestEnv after dispatch_doctor, a LOAD_PATH reset, or a custom
system image (-J) that contains MyPackage. Exiting with status 1.
```

**Rationale**

- The 0.1 behaviour was wrong in three ways:
  - A second call errored with a misleading child message (#44).
  - The D30 prototype silently ignored a second target, which fails open.
  - Stacking one environment per target loads the dependency's original code, depending on call order ($AUDIT/D49-target-cardinality-t4k9/exp2).
- Base logs exceptions thrown from package callbacks and carries on, so the load-identity check has to `exit(1)` ($AUDIT/D16-integrity-checks-r4n8/e1, e7).

**Tests**

- Every row of the process-kinds table.
- After every error row: `ENV`, `LOAD_PATH`, `DEPOT_PATH` and the atexit hooks are unchanged.
- A monorepo root that runs `Pkg.test` on a leaf with its own lines.
- JOIN with different runtime options gives a note; JOIN with different compile-time options gives an error.
- A nested `Pkg.test` prepends the redirect again.
- A guard child with an unconditional activation in `setup.jl` stays inert.

---

## D31 Environment-variable contract

**Decision.**

| name | set by | values | contract |
|---|---|---|---|
| `DISPATCH_CHECKUP` | user (`"on"`); DispatchCheckup (`"checked"`) | unset, `""` (same as unset), `"on"`, `"checked"` | Public and stable. Test files read it. Never set `"checked"` yourself. |
| `DISPATCH_CHECKUP_DEPOT` | user or CI | absolute path | Moves the private depot. A machine-level setting; tests must not read it. |
| `DISPATCH_CHECKUP_RUN` | DispatchCheckup only | absolute run directory, or `guard:<pid>` | Private. |
| `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH`, and `JULIA_PROJECT` when activation pinned the project | DispatchCheckup (export) | the injected environment prepended to the inherited `JULIA_LOAD_PATH`; the private depot appended (last) to the inherited `JULIA_DEPOT_PATH`; the pinned project | Lets descendants load the image (S2 D12). |
| any other `DISPATCH_CHECKUP_*` | — | — | Reserved. Ignored by DispatchCheckup rather than rejected; the banner names each one as "ignored (reserved prefix)". Consumers may keep reading their own variables under the prefix (for example a report-path variable) in test code (Resolved (default)). |

**Requirements**

- **Lifecycle**
  - `"checked"` is written last in ACTIVATE.
  - Descendants and precompile workers inherit it (S1: precompile workers are not descendants).
  - It stays set until the process exits and cannot be cleared mid-run, because test files read it when they are included.
- **Scope.** All changes stay local to the process and its descendants. They never reach the user's shell or later CI steps.
- **Build time.** Code that runs at build time must not read any `DISPATCH_CHECKUP*` variable for anything that affects generated code, because none is part of the image key (D45). The one carve-out is the D46 build gate, which reads `DISPATCH_CHECKUP_RUN` to refuse builds outside a live run and to write failure files; it never changes generated code (S2 D45, D46). A process that is generating output is never a run member.
- **Guard child ENV (Resolved (default)).** It is the pre-activation snapshot, minus every `DISPATCH_CHECKUP*` name, plus `DISPATCH_CHECKUP_RUN = "guard:<activating pid>"`. `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` are restored to their pre-activation values, unset included (conflict 16; S2 D18). Activation reached inside the guard child or its descendants is inert (state machine step 2).
- **Two documented idioms.** No others are documented.
  - Skip: `get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("test_guards.jl")`
  - Gate: `if !isempty(get(ENV, "DISPATCH_CHECKUP", "")) … end`. Never use `haskey`, and never `== "on"`.
- **Documented hazards**
  - A hand-set `"checked"` with the lines commented out silently skips guards. DispatchCheckup is not loaded then, so it cannot detect this.
  - A descendant that escapes the redirect runs original code with `"checked"` set. Escapes include `setenv`/`withenv` that override `JULIA_LOAD_PATH`, and remote workers. That descendant skips its guards and is not checked. The guard phase still runs every guard once against the original code.
  - Tests that inspect `ENV` or `LOAD_PATH` see values that differ from production. They belong in `original=`.

**Rationale**

- In-process `ENV` reaches `run(julia)` children, Distributed workers and precompile workers ($AUDIT/D31-env-contract-166445241/inherit.jl).
- `Pkg.test` forwards arbitrary variables but resets `JULIA_LOAD_PATH`.
- A `haskey` gate opens on `""` ($AUDIT/D40-matrix-gating-8555/Toy).
- All 17 internal consumer packages read a report-path variable under the prefix (`DISPATCH_CHECKUP_REPORT`, a 0.1-era convention) themselves in test code (the private consumer migration plan, S6b, maintained outside this repository), so names under the reserved prefix are ignored, not rejected.

**Tests**

- Inheritance through `run(julia)`, Distributed, ReTestItems and `compilecache`.
- `""` behaves as unset.
- Each invalid value gives its error.
- The guard child's ENV equals the snapshot minus the DispatchCheckup names plus the marker.
- `DISPATCH_CHECKUP_REPORT=x` is ignored and listed in the banner.

---

## D40 CI gate and GitHub Actions recipe

**Decision.** Gate both lines on a non-empty `DISPATCH_CHECKUP`, and add one separate checkup job that sets `DISPATCH_CHECKUP: "on"`. Unconditional lines remain supported: for local use, or for a CI that runs only Julia 1.13.

```julia
if !isempty(get(ENV, "DISPATCH_CHECKUP", ""))
    import DispatchCheckup
    DispatchCheckup.dispatch_doctor(:MyPackage; unstable = (:foo, :bar), original = ("test_guards.jl",))
end
using Test, MyPackage
# ...
get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("test_guards.jl")
```

```yaml
jobs:
  test:            # the ordinary matrix stays unchanged; DISPATCH_CHECKUP is never set here
    # ...
  checkup:
    name: DispatchCheckup (Julia 1.13, ${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest]      # macos-latest is also supported; Windows checked runs are experimental
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v2
        with:
          version: '1.13'
      - uses: julia-actions/cache@v2       # saves ~/.julia/compiled, including .dispatchcheckup
      - uses: julia-actions/julia-buildpkg@v1
      - uses: julia-actions/julia-runtest@v1
        with:
          coverage: false                  # coverage of instrumented code is meaningless
        env:
          DISPATCH_CHECKUP: "on"           # step level only, and always quoted
```

**Requirements (documented in the README)**

- Set the variable at step level, never at workflow level. At workflow level it would turn every leg and the docs job into checked runs.
- Quote `"on"`.
- Use `coverage: false`, and do not upload coverage from this job.
- The checkup job does not replace an ordinary Julia 1.13 leg.
- The ordinary matrix already runs the guards, so `original=` is optional in two-job setups.
- A matrix `include:` variant with `DISPATCH_CHECKUP: ${{ matrix.checkup }}` is safe only because `""` counts as unset.
- To keep the report as an artifact, pass `report = "dispatch-checkup.toml"`; it then lands in `test/`. Upload it with `if: always()`.
- Local use:
  - `DISPATCH_CHECKUP=on julia --project -e 'using Pkg; Pkg.test()'`;
  - or, from a REPL, `using Pkg; withenv(Pkg.test, "DISPATCH_CHECKUP" => "on")`.

**Rationale**

- The import is eager, so only a gate around the import leaves ordinary legs identical to the commented-out baseline.
- `Pkg.test` and julia-runtest forward job environment variables.
- YAML 1.1 parses an unquoted `on` as `true`.
- julia-runtest's `coverage` input defaults to true ($AUDIT/D40-matrix-gating-8555).

**Tests.** A fixture uses the gate. Run `Pkg.test` with the variable unset, `""` and `"on"`:

- When the gate stays closed, DispatchCheckup and DispatchDoctor are not in `Base.loaded_modules`.
- With `"on"`, the run is checked.

---

## D02 / D50 / D32 Guards (user view)

**Decision.**

- `original=` lists standalone guard files.
- After the checked suite and its validation, the activating process starts **one fresh ordinary Julia process**, which includes those files in order against the original code.
- Test files skip the guard files in checked runs with the skip idiom.

**User rules**

1. **Listing.**
   - Paths are relative to the activating file (D15). They must exist, the activating file itself is not allowed, and duplicates are dropped.
   - `original=` is ordinary Julia code, so it may depend on ARGS or ENV, for example `original = filter(in(TEST_RUN), GUARD_FILES)`. It is evaluated once.
2. **Leak check.**
   - If a listed file, compared by realpath, is included in the checked process or in any run member, an error is raised **before its body runs**: "test_guards.jl is listed in original= but was included in the checked run; skip it with `get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include(...)`". Validation also fails, even if the error is caught.
   - ParallelTestRunner auto-discovers `test/*.jl`, so exclude guard files from its list in checked runs.
3. **Standalone files.**
   - Each file is included into `Main` without `runtests.jl`'s setup, so it needs its own `using Test, MyPackage, ...`. That line is harmless in ordinary runs.
   - On an `UndefVarError`, the guard child prints that hint.
   - For shared setup, list the setup file first, or write `isdefined(@__MODULE__, :X) || include("setup.jl")`.
   - An activation call reached in the guard child or any of its descendants is inert (marker `DISPATCH_CHECKUP_RUN=guard:<pid>`).
4. **What the guard child gets.** It mirrors the activating process as it was before activation:
   - the same Julia binary and flags (`julia_cmd`, plus `--threads`, `--depwarn` and the rest per D18);
   - `--project=<active project>` only when the activating process had an explicit active project (`active_project(false)`; under `Pkg.test` it has none, and `LOAD_PATH` carries the project);
   - the pre-activation `LOAD_PATH`, with only `@script` expanded to an absolute path, and `DEPOT_PATH`;
   - the cwd and ARGS;
   - ENV as it was before activation, minus every `DISPATCH_CHECKUP*` name, plus the `guard:<pid>` marker, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored (D31);
   - `stdin = devnull`, inherited stdout and stderr, and `PROGRAM_FILE = ""`.

   It does not see variables that `runtests.jl` sets after the activation lines.
5. **Per-file results.**
   - Each file runs inside `@testset "original: <relpath>"`.
   - A failure does not stop the later files.
   - The report records each file as passed, failed, errored or not_run.
   - If a guard file calls `exit()` before the later files ran, the phase fails and names them.
6. **Order and status.**
   - The sequence is: suite, validation, report with guards marked pending, GC, guards, final report and summary.
   - The exit status is the **first nonzero of (suite, validation, guards)**.
   - Guards run even if the suite or validation failed.
   - Guards are **skipped**, and recorded as `interrupted`, on SIGINT or SIGTERM. DispatchCheckup sets `Base.exit_on_sigint(true)` at activation in non-interactive processes, so Ctrl-C under `Pkg.test` is detected and the exit code stays 130 or 143.
   - Guards are also skipped when the target never loaded.
7. **Costs and platforms.**
   - The checked process stays alive while the guards run, so peak memory is the sum of both, and GPU contexts stay held.
   - On Linux the guard child dies with its parent (`PR_SET_PDEATHSIG`). On macOS this is best effort, and on Windows experimental.

**Where checks belong (D32)**

| check | in the checked run | put it in |
|---|---|---|
| JET `test_package`/`report_package` (image load), ExplicitImports, Aqua `deps_compat`/`project_extras`/`undefined_exports`/`piracies`/`unbound_args`/`ambiguities` | Same verdict as production, through D13 original identity. | either |
| JET `@test_opt`/`@test_call` at concrete signatures; Aqua runtime checks | Unaffected. | either |
| Aqua `stale_deps` | Blind for the target's deps that DispatchCheckup loads itself (B = target `[deps]` ∩ the DispatchCheckup closure). When Aqua is loaded and B is not empty, one warning at the end says B "cannot be verified in this run". | `original=` |
| Package-level JET when the target is loaded from source (fallback) | Finds 0 reports, with a warning. | `original=` |
| `@test_opt`/`report_opt` at abstract signatures; exact method or ambiguity counts (simulator methods double them); allocation or timing assertions; `@inferred` through AD | Spurious failures. | `original=` |
| Tests that assert DispatchDoctor's (DD's) own behaviour, spawn production processes, or inspect ENV/LOAD_PATH | Diverge. | `original=` |

**Rationale**

- In the MiniDC simulation the guard process was pristine and exit codes merged correctly through `Pkg.test` ($AUDIT/D02-guards-x7k2q).
- 32 of 79 guard-like files in the corpus depend on `runtests.jl` setup (scan/).
- Under `-e`, Ctrl-C gives code 1 unless `exit_on_sigint` is flipped ($AUDIT/D50-guard-child-contract-x7k2/sig).
- `include_callbacks` fire before evaluation.
- JET, ExplicitImports and Aqua give production verdicts under D13 identity ($AUDIT/D32-guard-leak-detection-k5v8).

**Tests**

- The guard process is pristine: DispatchCheckup is not loaded, `pathof` points at the original, and `pwd`, ARGS and `LOAD_PATH` match production.
- Exit-code merging across suite, validation and guards.
- The leak check fires in the activating process and in a descendant.
- The `UndefVarError` hint.
- SIGINT under `Pkg.test`: guards are skipped and the exit code is 130.
- `exit()` inside a guard file.
- Shared setup that contains the activation lines is inert in the guard child.
- The `stale_deps` warning fixture.

---

## D22 Report schema v1 and console output

**Decision.** One versioned TOML report and one summary block, printed at the end.

**Report lifecycle**

- **Destination**
  - `report=nothing` writes `<private depot>/v<layout>/<Name>-<uuid8>-<crc32c8>/report.toml`. That is the D47 key directory. The file is overwritten on each run, and its path is printed in the banner and at the end.
  - `report="path"` writes to that path.
  - `report=false` writes nothing.
- **Placeholder and final write.**
  - Activation writes a placeholder holding `schema_version = 1`, `status = "incomplete"`, and `[run]` with `run_id`, `pid` and `started` (conflict 19, #31).
  - The final write is atomic: a temp file, then rename.
  - Any status other than `"passed"` means failure. A crash leaves `"incomplete"`.
- **Unwritable destination.** An explicit path that cannot be written is an error at activation. If the default location cannot be written, DispatchCheckup prints one line and the run continues.
- **Format**
  - Written with `TOML.print(sorted = true)`, ordered so that `schema_version` and `status` come first.
  - Null values are omitted, and Symbols are written as strings.
- **Stability levels**
  - **Stable core**: every field outside `[info]`. Within v1, changes are additive only. A removal or rename bumps `schema_version`.
  - **Informational**: `[info]`, which may change during 0.x.
- **Field values**
  - `status`: `incomplete`, `passed`, `failed`, `interrupted`.
  - `failures`: a subset of `suite`, `validation`, `instabilities`, `unstable_entries`, `blind_spots`, `guards`, `target_not_loaded`, `setup`.
  - `phases.guards.status`: `none`, `pending`, `passed`, `failed`, `skipped`, `interrupted`.
- **Kinds.** Each definition site has exactly one kind, so the counts add up:
  - `checked`, `unstable` (listed or in a source `@unstable` region), `by_design`, `limitation`, `informational`, `blind_spot`, `acknowledged`, `inactive`.
  - They map onto the S3.0 classes: `unstable` is `unstable_listed` without `acknowledged`; `acknowledged` is `unstable_listed` with `acknowledged = "blind_spot"`; `by_design` is `not_applicable`; `inactive` is an inventory site with no record (S3.5). The other kinds keep their S3.0 names. Reason codes and `origin` values (`dc`, `source_stable`, `source_unstable`, `native`) are S3's closed enums.
- **Limitations** are reported, never counted (D11): the report lists each limitation with its package-relative `file:line` and reason, and `[info].limitations` holds the per-reason counts (S3.9).

**Example** (validated with `TOML.parse`)

```toml
schema_version = 1
status = "failed"
exit_code = 1
failures = ["instabilities"]

[run]
run_id = "3f2c9a1e-5b7d-4c2a-9e1f-0a8b6c4d2e10"
started = "2026-10-19T14:02:11"
finished = "2026-10-19T14:09:47"
pid = 41213
julia = "1.13.2"
dispatch_doctor = "0.4.29"
dispatch_checkup = "0.2.0"
mode = "record"
union_limit = 1
require_all = false
activating_file = "/work/MyPackage/test/runtests.jl"
path_base = "activating_file"
report = "/Users/u/.julia/compiled/v1.13/.dispatchcheckup/v1/MyPackage-5b1e2a7c-9d04c3e1/report.toml"

[run.target]
name = "MyPackage"
uuid = "5b1e2a7c-0000-4000-8000-000000000001"
version = "1.4.0"
root = "/work/MyPackage"

[phases.suite]
exit_code = 0

[phases.validation]
status = "failed"
messages = ["2 unstable definitions recorded"]

[phases.guards]
status = "passed"

[[phases.guards.files]]
file = "test/test_guards.jl"
result = "passed"

[[instabilities]]
function = "MyPackage.solve"
file = "src/solve.jl"
line = 41
origin = "dc"
selector = ':solve => "src/solve.jl:41"'
count = 17

[[instabilities.signatures]]
args = ["Vector{Any}", "Float64"]
kwargs = ["tol::Float64"]
inferred = "Union{Nothing, Float64}"
context = "call"
count = 17

[[instabilities.signatures.raises]]
file = "test/test_solve.jl"
line = 22
testset = "MyPackage/solve"
task = "main"
pid = 41213

[[instabilities]]
function = "MyPackage.Mesh.cell_at"
file = "src/mesh/cells.jl"
line = 88
origin = "dc"
selector = ':cell_at => "src/mesh/cells.jl:88"'
count = 3

[[instabilities.signatures]]
args = ["MyPackage.Mesh.Grid{2}", "Int64"]
inferred = "Any"
context = "call"
count = 3

[[unstable_entries]]
entry = ":_finite_or_nothing"
state = "matched"
matched = 2
modules = ["MyPackage"]
sites = ["src/util.jl:12", "src/util.jl:15"]

[[unstable_entries]]
entry = 'Symbol("MyPackageCUDAExt.kernel_size")'
state = "inactive"
reason = "extension MyPackageCUDAExt not loaded"
sites = ["ext/MyPackageCUDAExt.jl:30"]

[[unstable_entries]]
entry = ":solve!"
state = "matched"
matched = 3
modules = ["MyPackage", "MyPackage.Krylov"]
note = "matched definitions in 2 modules; qualify the entry or use a site entry to narrow it"

[[extensions]]
name = "MyPackageCUDAExt"
state = "not_loaded"
triggers = ["CUDA"]

[info]
load_mode = "image_reused"
limitations = { parametric_name = 5, incompatible_name = 3 }
counts = { checked = 812, unstable = 14, by_design = 32, limitation = 8, informational = 6, blind_spot = 0, acknowledged = 0, inactive = 2 }
analyzer_warnings = []
allowed = 0

[[info.processes]]
pid = 41213
role = "activating"
clean_exit = true
```

**Console contract**

- **Banner** at activation, at most three lines plus any re-printed precompile output:
  - versions and options;
  - whether the image was reused or built, with the time and what was rebuilt;
  - the guard list, the report path, the path base and any ignored reserved variables.
- **Precompile output.** The output of the eager precompile is captured. DispatchDoctor's (DD's) "no compatible functions" warnings are dropped, and the rest is re-printed before the tests start (conflict 12).
- **During the suite** DispatchCheckup prints nothing. A scoped logger filter drops only DD's decline warning, and the recorder never logs. Joined descendants never print.
- **Phase banners** appear only at phase boundaries, such as the start of the guards.
- **Final block**
  - Written straight to `stderr` after `flush(stdout)`, never through logging, so a suite's Warn-level global logger cannot hide it.
  - Contents, in order:
    - one line per phase;
    - definition counts, with limitations grouped by reason (each limitation's site is listed in the report);
    - `unstable=` states and notes;
    - blind spots;
    - extensions that were not loaded;
    - dependents built lazily after activation, as `lazy` warnings (D51);
    - each unstable definition with up to 3 signatures and "+N more";
    - a copy-pasteable `unstable` line;
    - the report path;
    - a one-line verdict.

```
DispatchCheckup 0.2.0: checking MyPackage 1.4.0 (Julia 1.13.2, DispatchDoctor 0.4.29, mode=record, union_limit=1, require_all=false)
DispatchCheckup: instrumented image reused (MyPackage + 0 of 1 extensions)
DispatchCheckup: guards after the suite: test/test_guards.jl; report: ~/.julia/compiled/v1.13/.dispatchcheckup/v1/MyPackage-5b1e2a7c-9d04c3e1/report.toml
... the suite's own output ...
──────── DispatchCheckup: running original= guards (1 file) against the original code ────────
... guard output ...
──────── DispatchCheckup summary: MyPackage ────────
suite        passed (exit 0)
validation   FAILED: 2 unstable definitions
guards       passed (1 of 1 file)
definitions  812 checked · 14 unstable= · 32 by design · 8 DispatchDoctor limitations (5 parametric name, 3 callable object or qualified name) · 0 blind spots
unstable=    13 matched · 1 inactive: Symbol("MyPackageCUDAExt.kernel_size") (extension MyPackageCUDAExt not loaded)
note         :solve! matched definitions in MyPackage and MyPackage.Krylov; use Symbol("MyPackage.solve!") or a site entry to narrow it
not loaded   MyPackageCUDAExt (needs CUDA)
unstable definitions (2):
  MyPackage.solve  src/solve.jl:41  (17 calls)
    solve(::Vector{Any}, ::Float64; tol::Float64) -> Union{Nothing, Float64}   first at test/test_solve.jl:22 [MyPackage/solve]
  MyPackage.Mesh.cell_at  src/mesh/cells.jl:88  (3 calls)
    cell_at(::Grid{2}, ::Int64) -> Any   first at test/test_mesh.jl:140 [MyPackage/mesh]
to stop checking them, add to unstable: :solve => "src/solve.jl:41", :cell_at => "src/mesh/cells.jl:88"
report       ~/.julia/compiled/v1.13/.dispatchcheckup/v1/MyPackage-5b1e2a7c-9d04c3e1/report.toml
DispatchCheckup: FAILED (2 unstable definitions; exit 1)
```

A target whose owned modules all have inference disabled (O10) passes with `GodelaAMGX_jll: nothing checkable — inference disabled in every owned module` (see S6a).

**Rationale**

- `@test_nowarn` fails on any output to stderr (#121).
- A global logger can drop an `@info` summary ($AUDIT/devil-D22-report-output-r7q4/atexit_log.jl).
- TOML round-trips the schema and handles 20k records in 0.14 s (toml_probe.jl).
- Before the placeholder rule, a crash left a stale "passed" report (#31).
- On DataStructures, re-running a suite to see detail the console cut off cost 3–16 minutes per iteration, so a report file is written by default.

**Tests**

- The placeholder exists right after activation.
- After `ccall(:abort)` the report says `"incomplete"`.
- Output is deterministic.
- A schema test checks the fixture reports.
- `@test_nowarn using MyPackage` passes in a checked run.
- `global_logger(ConsoleLogger(stderr, Logging.Warn))` does not hide the summary.
- `report=false` writes no file. An unwritable explicit path errors at activation.

---

## D51 As-if-absent contract and compat table (O1, O14)

**Contract.** With the two lines commented out, or the gate closed, on Julia 1.13 or later, a test run is observably identical to the same run with DispatchCheckup removed from the test environment, apart from the listed exclusions. This holds as long as the environment satisfies the compat table.

**Guaranteed observables**

- `Base.loaded_modules`, with versions.
- `Base.pkgorigins`, including the `cachepath` of the target and its dependents: they load the same cache files.
- `ENV`, `LOAD_PATH`, `DEPOT_PATH` and the active project.
- The Test counts and the exit status.
- All output of the test process from "Testing Running tests..." on, with timings normalised.
- **History independence.** The sequence unchecked, checked, unchecked gives identical observables. A checked run leaves these byte-identical:
  - the package tree;
  - the test Project, Manifest and LocalPreferences;
  - the user depot's compiled entries for the target and its extensions.
  
  DispatchCheckup writes instrumented target and extension images only inside the private depot, and never symlinks or hardlinks into the checkout. The one write outside it is a dependent built lazily after activation (Checked runs, below): it adds a file to the user depot under a distinct cache slug and never overwrites a production file in place.

**Excluded**

- Everything Pkg prints before "Testing Running tests...": the Status listing, which includes the DispatchCheckup closure; resolve messages; precompile progress for DispatchCheckup and DispatchDoctor.
- The extra manifest entries.
- Wall time.

**Resolution is additive-only.** The manifest with DispatchCheckup equals the manifest without it, plus closure packages that were not already present. Every package present in both keeps its version.

**Compat table**

| package | in the closure because | DispatchCheckup `[compat]` | your test environment must satisfy | checked runs also need |
|---|---|---|---|---|
| julia | — | `"1.13"` | Julia 1.13 or later on every leg that resolves the test environment. Packages whose matrix includes Julia below 1.13 cannot declare DispatchCheckup in 0.2: resolution fails on those legs. | Julia 1.13.x |
| DispatchDoctor | direct dependency | `"0.4"` | any 0.4.x | ≥ 0.4.29 (fail-closed at activation) |
| MacroTools | direct dependency (also a DispatchDoctor dependency) | `"0.5"` | any 0.5.x | ≥ 0.5.12 (fail-closed at activation; Resolved (default), re-measured after the walker refactor) |
| Preferences | direct dependency, because D45 reads the compile-time table through its public `load_preference` (O14's condition holds); also a DispatchDoctor dependency | `"1"` | 1.x | — |
| TOML | stdlib | `"1"` | — | — |
| Dates, Printf | stdlibs pulled in by TOML or DispatchDoctor | — | — | — |
| ChainRulesCore | DispatchDoctor weakdep | (DispatchDoctor: `"1"`) | 1.x, if present | — |
| EnzymeCore | DispatchDoctor weakdep | (DispatchDoctor: `"0.6, 0.7, 0.8"`) | 0.6–0.8, if present | — |

- **When a condition fails**, Pkg reacts in one of two ways:
  - an `Unsatisfiable requirements` error before the tests run;
  - a silent re-resolve, announced only by "Could not use exact versions of packages in manifest, re-resolving". That changes the versions under test, so runtime equivalence is lost.
- **Checked runs.** The contract does not cover a checked run.
  - The eager import loads DispatchCheckup, DispatchDoctor, MacroTools, Preferences, TOML, Dates and Printf, and target extensions that these trigger also load. That is why guards run in a fresh process.
  - **Builds after activation (Resolved (default)).**
    - The D46 gate refuses to build an instrumented target or extension image after activation, and the run fails loud. This is a documented divergence from production: for example, a late-triggered extension whose image was not built at activation, or an environment that the tests create, cannot load the target in a checked run.
    - Dependents may be built lazily after activation. They land in the user depot under a distinct cache slug (the slug carries the D45 preference), never overwrite a production file in place, and are reported as `lazy` in the summary and the report. They only add files that count toward Base's 10-file eviction per package.
- **Platforms (D25)**
  - Resolve, precompile, import and the closed gate are covered on Linux, macOS and Windows.
  - Checked runs are supported on Linux and macOS, and experimental on Windows. On any other operating system, activation fails closed (Resolved (default)).

**Rationale**

- A narrower compat silently upgraded a locked MacroTools 0.5.13 to 0.5.16, and a locked DispatchDoctor 0.4.25 to 0.4.29, in unchecked runs ($AUDIT/D20-dependency-footprint-m3q8/runs/pkgtest, pkgtest-dd).
- Compat equal to DispatchDoctor's changed nothing, and identical cache files were observed ($AUDIT/D26-test-strategy-m3k8/out/b1 vs w1).
- DispatchDoctor's EnzymeCore weakdep compat makes resolution fail outright when the user's own compat excludes 0.6–0.8 ($AUDIT/devil-D51-as-if-absent-scope-k4r7).

**Tests** (the D26 twin harness, on Julia 1.13)

- Lines commented out versus DispatchCheckup removed, comparing the guaranteed list.
- A fixture with an older MacroTools 0.5.x locked, and one that is DispatchDoctor-native with DispatchDoctor 0.4.25 locked: neither moves in the unchecked run, and the checked run gives the floor error.
- Newest ChainRulesCore and EnzymeCore.
- `Aqua.test_all` with the Quick-start snippet.
- The history sequence unchecked, checked, unchecked.

---

## O15 / D33 Removed API

**Decision.** These are **deleted outright in 0.2.0**, with no stubs, error hints or deprecation period:

| removed | what users see in 0.2 |
|---|---|
| `DispatchCheckup.test_original(; test_args, env)` | ``UndefVarError: `test_original` not defined in `DispatchCheckup` `` with the file and line. |
| `DispatchCheckup.source_root(M)` | The same `UndefVarError`. `isdefined(DispatchCheckup, :source_root)` is false. |
| `entrypoint=` keyword | `MethodError` "got unsupported keyword argument "entrypoint"", which lists the six keywords. |
| internal bridges (`_child_main`, `_original_main`, `_instrument_entry`, `Implementation`) | gone |
| the lazy facade ("importing performs no setup") | `import DispatchCheckup` now loads DispatchDoctor and its closure eagerly. Hence the D40 gate. |

- **Release.** 0.2.0 merges from `redesign-0.2` into `main` with a merge commit, not a squash (Resolved (default)), and is tagged `v0.2.0`. v0.1.2 is already tagged, at 2fd0449.
- **Effect on consumers.** All 14 internal consumer repositories (17 packages) are in scope (Resolved (default)). They keep `[compat] DispatchCheckup = "0.1.2"` and `rev = "main"`. Once 0.2.0 is on main, their resolution fails loudly with "empty intersection between DispatchCheckup@0.2.0 and project compatibility 0.1.2 - 0.1" before any test code runs. Each consumer migrates by bumping compat to `"0.2"` and applying the section below.
- **Coordination.** The merge must be coordinated with the consumer sweep. Per-repository migration detail and the rollout order are in the private consumer migration plan (S6b, maintained outside this repository). **Open for the owner (Q1):** the rollout path for the open consumer integration PRs, and whether a temporary `rev = "v0.1.2"` pin is allowed as a merge-day fallback.

**Rationale.** The only users are the owner's internal consumer repositories. A stub would only be reached after a deliberate compat bump. And stubs would break the 0.1-era `isdefined(DispatchCheckup, :source_root) ? … : pkgdir(M)` fallbacks that consumers use ($AUDIT/D33-removed-api-migration-m5t8/run2.log, run3.log).

**Tests**

- `isdefined(DispatchCheckup, :test_original) == false`, and likewise for `:source_root`.
- `names(DispatchCheckup)` contains only `:DispatchCheckup` and `:dispatch_doctor` among public names.
- Passing `entrypoint=` is a `MethodError`.

---

## Migrating from 0.1 (user section)

**Steps**

1. **Compat.** Set `DispatchCheckup = "0.2"` in `[compat]` and keep `rev = "main"`.
2. **Activation call.** Keep the call at the top of `runtests.jl`. Add `original=` with your guard files. Dropping `report = get(ENV, "DISPATCH_CHECKUP_REPORT", nothing)` is recommended but optional:
   - A report is now always written, and its path is printed.
   - `DISPATCH_CHECKUP_*` is a reserved prefix. DispatchCheckup ignores unknown names under it and lists them in the banner, and test code may keep reading its own (Resolved (default), D31).
   - For a fixed CI path, pass `report = "dispatch-checkup.toml"`, or read a variable outside the prefix.
3. **Guard call sites.** Replace every `test_original` call with the skip idiom and list the file in `original=`:

| 0.1 idiom | 0.2 idiom |
|---|---|
| `DispatchCheckup.test_original(test_args=["test_guards.jl"]) \|\| include("test_guards.jl")` | `original = ("test_guards.jl",)` in the call, and `get(ENV, "DISPATCH_CHECKUP", "") == "checked" \|\| include("test_guards.jl")` |
| `file in GUARD_FILES && DispatchCheckup.test_original(test_args=[file]) && return nothing` | Define `const GUARD_FILES = (...)` **before** the two lines and pass `original = GUARD_FILES`. Then write `file in GUARD_FILES && get(ENV, "DISPATCH_CHECKUP", "") == "checked" && return nothing`. |
| `f == "test_guards.jl" && DispatchCheckup.test_original(; test_args=[f]) && continue` | `f == "test_guards.jl" && get(ENV, "DISPATCH_CHECKUP", "") == "checked" && continue`, with the file listed in `original=` |
| an environment-group selector, such as `g == "guards" && DispatchCheckup.test_original(; env=["MYPKG_TEST_GROUP" => "guards"]) && continue` | `original = TEST_GROUPS["guards"]` (define the table before the call) and `g == "guards" && get(ENV, "DISPATCH_CHECKUP", "") == "checked" && continue`. If the group's files rely on shared helpers, list the helper file first. |
| `DispatchCheckup.test_original() \|\| include("test_guards.jl")` (re-ran the whole entry) | Name the file in `original=` and use the skip idiom. Make the file standalone if it used the entry's fixtures. |
| A file that calls `test_original` on itself, mixing checked and original parts | Split the original-only part into its own guard file. A listed file must never be included in the checked run. |
| `test_original` in a secondary file (another test file includes `test_guards.jl`) | Use the skip idiom in that file and list the guard in `original=`. |
| `isdefined(DispatchCheckup, :source_root) ? DispatchCheckup.source_root(M) : pkgdir(M)`, or a `Base.loaded_modules[PkgId(<DC uuid>)]` lookup | `pkgdir(M)`. Under 0.2, `pathof` and `pkgdir` report the checkout. |
| a stray `import DispatchCheckup` outside `runtests.jl` | Delete it. The only references to DispatchCheckup are the two lines (O1). |

4. **Standalone guards.** Add `using Test, MyPackage, ...` to any guard file that relied on `runtests.jl` setup.
5. **Re-check `unstable=` entries.**
   - A bare `:foo` now also matches submodules and extensions; read the summary's multi-module notes.
   - `Symbol("<callable>")` and malformed keys such as `Symbol("Pkg...")` now error.
   - Entries in extensions that a leg does not load are `inactive`, not errors.
   - Lists may be any iterable, such as `keys(nt)`.
6. **First checked run.**
   - Record mode lists every instability in one run. Use the printed `unstable` line, or prefer site entries for definitions you accept.
   - Consider `union_limit = 2` for `Union{Nothing, T}` families.
7. **CI.** Gate the lines and add the checkup job (D40). Run with `coverage: false`.

**Behaviour changes that are not removals**

- The suite runs once, in-process. There is no child relaunch, and the process no longer calls `exit(status)` mid-run.
- Instabilities fail at the end by default instead of throwing at the call. Use `mode = :error` for the old behaviour while debugging.
- Relative `report=` paths resolve against the activating file, not the cwd.
- `require_all` counts only blind spots, so nested closures no longer fail it.
- DispatchCheckup prints nothing during the suite.
- REPL and notebook activation is refused.

---

## Open points

Every point below except the owner question at the end is settled. Items 1 and 3 to 12 are **Resolved (default)**: they follow the lead reviewer's recommendation, which the owner accepted for every item the owner did not decide.

1. **D11, eval blind spots. Resolved (default).** A non-literal `eval` site has no written name. This spec acknowledges it through the audited method names it defines, counted by name and line; an eval site that defines no owned method is informational (D11). The coverage section (D44) implements this.
2. **D09, preference and generated wrappers.** The target's `dispatch_doctor_union_limit` preference does not affect DispatchCheckup-generated wrappers here, because `union_limit=` governs them; it is only reported. D09's challenger proposed a conflict error instead. **Settled by O6**: `union_limit=` is the global default for DispatchCheckup-generated wrappers, and source annotations keep their own limit. The preference is therefore only reported, and no conflict error is added.
3. **D12 against D31, missing redirect in a descendant. Resolved (default).** This spec prepends the redirect again when the target is not loaded yet (D12(5)), rather than erroring (D31(4)). Once the target is loaded, it is the "already loaded" error.
4. **D02 against D29 and D31, the guard marker. Resolved (default).** Activation reached inside the guard child or any of its descendants is **inert** (marker `DISPATCH_CHECKUP_RUN=guard:<pid>`). D02's prototype threw instead, with a pid check. The guard child's ENV is the pre-activation snapshot minus every `DISPATCH_CHECKUP*` name, plus that marker, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored to their pre-activation values (D31).
5. **Grammar choices. Resolved (default).** These close the grammar further than the owner's text states, and are adopted as the section recommends:
   - Site-entry keys must be bare names.
   - `report` paths must end in `.toml`.
   - Unknown `DISPATCH_CHECKUP_*` variables are ignored by DispatchCheckup and listed in the banner. Consumers may keep reading their own variables under the prefix (for example a report-path variable such as `DISPATCH_CHECKUP_REPORT`) in test code, as S6a also notes.
6. **D20, MacroTools floor. Resolved (default).** The activation-time fail-closed check `pkgversion(MacroTools) >= v"0.5.12"` is adopted, in addition to `pkgversion(DispatchDoctor) >= v"0.4.29"`. It comes from D20's measurement, not from O14. Re-measure it once the walker is refactored (D01 P2).
7. **D47 against D17, default report path. Resolved (default).** The default report is `report.toml` in the target's D47 key directory of the private depot (D22). Its exact path follows whatever private-depot layout the Phase-1 prototype commits (the dev/ and packages/ mirroring question, S2 and S5). The API does not change either way: the path is printed in the banner and at the end.
8. **O6 against D11, `require_all` scope. Resolved (default).** O6 says `require_all` fails on "code that could not be checked" that is not listed. The D11 reading applies: only blind spots not listed in `unstable=` are counted; DD limitations are reported with their locations and counts, and never counted. The literal O6 reading would require listing every limitation (about 207 entries on StaticArrays).
9. **`unstable=` on a definition with its own explicit source `@stable`. Resolved (default).** DD's native check stays, as in production: DD's `@unstable` is a no-op that only hides code from implicit wrapping, and an explicit author-written `@stable` still applies. Members of a source `@stable` block that are listed in `unstable=` are emitted unwrapped (D10, S3.10).
10. **Two atexit hooks. Resolved (default).** The finalizer (validation, report, guards, exit status) and the D50 reaper, which only kills a guard child still alive after a signal, are both registered (state machine, ACTIVATE step 7).
11. **Operating systems. Resolved (default).** Activation fails closed on operating systems other than Linux, macOS and Windows (state machine step 5; S5 D25).
12. **Builds after activation. Resolved (default).** The D46 gate refuses to build an instrumented target or extension image after activation, and the run fails loud; this is a documented divergence (D51). Lazy builds of dependents after activation are allowed: they land in the user depot under a distinct cache slug that carries the D45 preference, never overwrite a production file in place, and are reported as `lazy`.
13. **Owner items. Settled.** The only owner items are O0, O1, O4, O6, O10, O14 and O15.

**Still open for the owner**

- **Q1, consumer rollout.** The rollout path for the open consumer integration PRs, and whether a temporary `rev = "v0.1.2"` pin is allowed as a merge-day fallback (O15 / D33 "Coordination"; details in the private consumer migration plan, S6b, maintained outside this repository).

**Conflict resolutions applied:** 4, 5, 10 (refined by D50), 12, 16, 18, 19 and 20. Conflict 7 (`waive=`) and conflict 23 (DD output rewrites) are superseded by O6 and O4.

**Straightforward fixes absorbed here:**

- #44 (repeat call), #49 (README compat), #31 (stale report), #60 (early exit), #59 (flush before spawn), #75/#120 (DispatchDoctor warnings), #40 (closure targets), #119 (`@main`, via atexit), and #71/#92/#95/#70/#116 (docstring and README rewrite).
- #56 and #57/#63/#29 are moot under D13.

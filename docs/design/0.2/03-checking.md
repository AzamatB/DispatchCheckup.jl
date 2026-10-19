# S3 Checking semantics

This section specifies what DispatchCheckup (DC) 0.2.0 wraps, what the generated check does at run time, what is recorded, and how coverage is judged. Other sections own the process model (D30), environments (D24), overlays and images (D13, D04, D17/D47), the compile-time configuration table (D45), the per-image private submodule and include observer (D46), descendants (D12), the report file (D22) and the `unstable=` grammar and validation timing (O6 API section). This section states only the interfaces it needs from them.

**Conventions.** MUST, SHOULD and MAY are normative. `$AUDIT` is the maintainer's local review archive (not part of this repository), as defined in S1; evidence is cited as `$AUDIT/<directory>`. `#N` is finding N in `$AUDIT/review.json`. "DD" is DispatchDoctor 0.4.29 unless a version is named. Julia 1.13.x only (O14).

**Terms.**
- *walker*: the syntax core kept from `instrumentation.jl` (D01): the include mapper and the top-level traversal. It is pure.
- *marker*: a DC macro call that the walker emits around one definition (`DispatchCheckup.@_check`) or one block (`DispatchCheckup.@_block`). It expands inside the target module after the preceding top-level statements have run, so it can resolve bindings. It is pure.
- *template*: the expression that `@_check` returns for a checkable definition (S3.1).
- *site*: one syntactic definition, identified by (original file, first line, ordinal, module path). A wrapped site carries one `Site` object.
- *record*: one evaluation-time fact about a site, pushed into the image's sink (S3.5).
- *private submodule*: `var"#DispatchCheckup"`, the first statement of the target root module and of each extension root module (D46). It holds the sink, the canaries and the load hook.
- *owned module*: a module whose `Base.PkgId(Base.moduleroot(m))` equals the target's PkgId or the PkgId of one of the target's extensions, `uuid5(target_uuid, extname)` (#23).
- *pure*: has no effect outside the expression it returns. No record pushes, no `Core.eval`, no writes to DC or package state, no IO, no logging.

## S3.0 Record classes (shared vocabulary)

Every site that the walker sees gets exactly one class and one reason code. D11 (S3.9) defines which classes `require_all` counts.

| class | contents | counted by `require_all` |
|---|---|---|
| `checked` | Wrapped by DC's template (origin `dc` or `source_stable`), or checked natively by DD where DC cannot reach the annotation (origin `native`, found by the D44 audit). | no |
| `unstable_listed` | Matched by an `unstable=` selector, or inside a source `@unstable` region (origin `source_unstable`). Emitted unwrapped. | no |
| `not_applicable` | A check means nothing here, or the code never runs in the checked process. Covers the `by_design.*` reasons (S3.4), macro definitions, non-defining macros, quoted templates and test-only bodies. | no |
| `informational` | Nested closures (the outer return is checked), definitions evaluated into modules that are not owned, and runtime includes that run natively. | no |
| `limitation` | Forms DD declines, and vetted `skip` entries in the macro table (S3.7). | no |
| `blind_spot` | Unvetted decorators, opaque macros that define methods, non-literal top-level eval that defined owned methods, and methods the audit cannot account for. | yes, unless listed in `unstable=` |

Four lists are kept apart from the records: *instabilities* (S3.1.1), *leniencies* (S3.1.3), *allowed* events (S3.1.1) and *inactive* sites (S3.5).

---

## S3.1 O4/D21 Owned wrapper template

**Decision.** DC generates its own per-definition check wrapper. The template is derived from DD 0.4.29's `_stabilize_fnc` (Apache-2.0; SPDX header, `LICENSES/Apache-2.0.txt`, `THIRD_PARTY_NOTICE.md`, D38). It calls DD's runtime helpers by reference. For code that DC wraps, DC never macroexpands DD's `@stable` and never patches DD output. DC writes no DD preference keys. Recorder, AD transparency, the Type-keyword gate, long tuples, simulator source lines, baremodule-safe code and inner constructors are properties of the template, not rewrites.

**Requirements.**
- R1 **DD surface.** The template and its helper use only these DD names, all from inside function bodies:
  - `_Utils`: `specializing_typeof`, `_promote_op` (both methods), `type_instability`, `type_instability_limit_unions`, `sanitize_arg_for_stability_check`, `extract_symbol`, `has_nospecialize`, `is_function_name_compatible`.
  - `_RuntimeChecks`: `checking_enabled`.
  - `_Interactions`: `ignore_function`.
  - `_Stabilization`: `_show_warning`, which DC extends for its own `Site` type.
  - `TypeInstabilityError`.

  Adding a name requires a new self-test entry (S3.2).
- R2 **Pure generator.** `template(def::Expr, facts::SiteFacts, opts::TemplateOpts)::Union{Expr,Nothing}` is a pure function. Only the `@_check` marker calls it.
- R3 **Inputs.** `TemplateOpts` holds:
  - `union_limit::Int`, the effective limit from S3.3;
  - `inner_ctor::Bool`;
  - `global_decl::Bool`;
  - `decorators`, an ordered list of (macro head, `:both` or `:outer`) from S3.7;
  - `origin`, which is `:dc` or `:source_stable`;
  - `canary::Bool`.

  `mode` is not an input (D03). `union_limit`, the selector table, the macro-table version and the template version are compile-time inputs and belong in the D45 table.
- R4 **Declines** mirror DD exactly. The template returns `nothing` for:
  - a curly-named definition (`func[:params]` not empty): `limitation(parametric_name)`;
  - `!is_function_name_compatible(name)`, which covers functors, `(::Type{X})(…)` and nested-qualified names: `limitation(incompatible_name)`;
  - `has_nospecialize` in the arguments or keywords: `not_applicable(by_design.nospecialize)`.

  The marker then emits the original definition (#85 gives the precise reasons).
- R5 **Fixed properties.**
  - F1 *Simulator.* A `deepcopy` of the definition with only its name replaced by `gensym("<name>_dcsim")` (`anonymous_function_dcsim` when there is no name). There is no `rmlines`. Every `LineNumberNode` and every macrocall `__source__` is kept. File paths are the original checkout paths, because D13 includes the original sources in place (#13, #18). The distinct `_dcsim` infix lets the D44 audit tell DC simulators apart from DD-native `_simulator` ones.
  - F2 *Wrapper body*, in order:
    1. the definition's own first `LineNumberNode`, or the site line if it has none;
    2. exactly one prologue call (F3);
    3. DD's destructurings for `_`, tuple and `(; …)` arguments;
    4. the remaining original body statements, unchanged.

    The signature changes only through DD's argument sanitization. `Method.line` and `functionloc` equal production (#18).
  - F3 *Prologue.* One direct call `DispatchDoctor._Stabilization._show_warning(site, sim, self, args, kw, params, Val{L}())` (S3.1.2). Arguments are values, never types. It returns `nothing`. No other statement is generated.
  - F4 *Hygiene.* Generated code contains only literals, the spliced `Site` and `Val` objects, `GlobalRef`s, tuples, named tuples and DD's destructuring assignments. It has no bare operator or function symbol (`!`, `throw`, `map`, `typeof`), no indexing or `ref` syntax, and no `begin`/`end` indices. It therefore works in a `baremodule` (replacing the Base-qualified `!` rewrite) and survives `@views` and `@fastmath` walking the expansion (D07).
  - F5 *Codegen shape.* Only DD's `"debug"` shape. The body runs in the wrapper, and the simulator is only ever passed to inference. Source `default_codegen_level` options and DD codegen preferences have no effect.
  - F6 *`self`* is `var"#self#"` for named functions. It is `nothing` for anonymous functions and inner constructors (#20).
  - F7 If the source wrote `global f(…) = …`, the output begins with `global f, <simulator name>` (#2).
  - F8 *Decorators.* `:both` re-applies each decorator to the simulator and the wrapper in DD's order. `:outer` applies it to the wrapper only. `Core.@__doc__` stays outermost on the wrapper.
  - F9 *Stable path.* When inference proves the return type stable, the prologue folds away: zero allocations and no dynamic call.
- R6 **Generated shape.** The pseudo-code below is normative in structure. Names are illustrative.

```julia
# Source (src/ops.jl:12, module MyPkg.Sub), decorator @inline vetted as :both:
#   @inline function Base.:+(a::Foo{T}, (x, y)::Tuple, _; scale::Type = Float64) where {T}
#       ...body...
#   end
# Walker output (pure; the facts are literals):
#   DispatchCheckup.@_check $FACTS @inline function Base.:+(...) ... end
# Marker expansion in MyPkg.Sub:
begin
    # F7 only (source wrote `global g(...) = ...`): global g, var"##g_dcsim#41"
    @inline function var"##+_dcsim#41"(a::Foo{T}, (x, y)::Tuple, _; scale::Type = Float64) where {T}
        #= src/ops.jl:12 =#                    # verbatim copy: lines and __source__ kept (F1)
        ...body...
    end
    Core.@__doc__ @inline function Base.:+(a::Foo{T}, var"##arg#42"::Tuple, var"##arg#43";
                                           scale::Type = Float64) where {T}
        #= src/ops.jl:12 =#                    # the definition's own first line (F2)
        $(GlobalRef(DispatchDoctor._Stabilization, :_show_warning))(
            $SITE,                             # DC-owned mutable Site, spliced (serialized in the image)
            var"##+_dcsim#41",                 # simulator: inference only
            var"#self#",                       # `nothing` for anonymous fns / inner ctors (F6)
            (a, var"##arg#42", var"##arg#43"), # raw positional values, Type values included
            (; scale),                         # raw keyword values
            (T,),                              # where-parameter values
            $(Val{1}()))                       # effective union limit, spliced instance
        (x, y) = var"##arg#42"                 # DD's destructurings
        _ = var"##arg#43"
        ...body...                             # remaining original statements
    end
    $(GlobalRef(ROOT.var"#DispatchCheckup", :record!))($RECORD, Base.:+)   # D05 evaluation-time record
end
```

- R7 **Helper.** DC defines this method. `Site` is DC-owned, so this is not type piracy.

```julia
@inline function DispatchDoctor._Stabilization._show_warning(site::Site, sim::F, self,
        args::Tuple, kw::NamedTuple{K}, params::Tuple, ::Val{L}) where {F,K,L}
    S = argtypes(args)                                  # S3.1.4 (fixed size) and S3.1.5 (Type values)
    T = isempty(K) ? DD._Utils._promote_op(sim, S...) :
                     DD._Utils._promote_op(Core.kwcall, typeof(kw), F, S)   # DD's own keyword check
    bad = L > 1 ? DD._Utils.type_instability_limit_unions(T, Val(L)) : DD._Utils.type_instability(T)
    bad && !isempty(K) && (bad = keyword_retry(site, sim, S, kw, T, Val(L)))   # S3.1.3, @noinline
    if bad && !DD._Interactions.ignore_function(self)
        record(site, S, kw, params, T, args, !DD._RuntimeChecks.checking_enabled())   # S3.1.1, @noinline
    end
    return nothing
end
```

- R8 **Precompile safety.** DC's top level defines R7 only under `isdefined(DD, :_Stabilization) && isdefined(DD._Stabilization, :_show_warning)`. No other top-level code touches DD internals. DC's own precompilation therefore succeeds against any DD 0.4.x, and the failure is reported at activation (S3.2). DC SHOULD ship a precompile workload for the template generator (measured cold JIT 4.35 s), wrapped in `try`/`catch` so that DD drift cannot break DC's precompilation. No new dependency is added.
- R9 **Divergences** from DD `@stable`. Each is listed in the README and in `docs/design.md` and has a regression test:
  1. record-and-continue default, with a runtime mode switch (D03);
  2. a collapsed, AD-inactive prologue (D42);
  3. Type-valued keywords are retried as singletons (D43);
  4. argument-type tuples are built at known size (D23);
  5. the simulator keeps source lines and `__source__` (#13);
  6. no bare operators, so `baremodule` works;
  7. inner constructors are checked (#20);
  8. Type values passed as arguments are `Type{X}` even when `X <: Type` (#82);
  9. debug shape only (F5);
  10. the mode of source annotations is overridden (S3.3);
  11. unknown decorators are denied (S3.7);
  12. wrapped methods keep the definition's file and line (plain DD methods loaded from an image show `none:0`, D44);
  13. raises suppressed by `allow_unstable` are recorded as `allowed`;
  14. no throw in a generator or a finalizer.

**Rationale.** Patching DD output already needed four rewrites (`_specialize_doctor_arguments`, `_restore_doctor_sources`, `_qualify_doctor_wrapper`, `_qualify_generated_negation`, `src/instrumentation.jl:320-432`), and the decided set needed about seven. The D21 prototype (`$AUDIT/D21-dispatchdoctor-coupling-t5n8/exp/own_template.jl`, about 70 lines) passed 21 of 21 checks. On a 20-function corpus it matched stock DD 20 of 20 (`exp/parity.jl`). It stayed green under the three simulated 0.4.30 refactors and under PR #109. Current DC fails each of those variants. The helper names are unchanged from v0.4.12 to v0.4.29.

**Tests.**
- Parity corpus against stock DD `@stable`: per-call verdicts are identical except for the R9 divergences.
- The D21 drift environments v1, v2, v3b and v4 (`$AUDIT/D21-dispatchdoctor-coupling-t5n8/env_*`).
- Shape fixtures: operators, `Base.:+`, anonymous functions, `where`, varargs, destructuring, `_`, slurped keywords, docstrings, `baremodule`, `@__DIR__` and command literals in the body (`$AUDIT/transform-review-k7q2/cases/c20_dirmask`, `c07a_anoncmd`, `c07b_opcmd`), and 40 arguments.
- A census assertion in the test suite: each wrapped definition produces exactly one simulator, one prologue call and one record push.

### S3.1.1 D03 Recorder and modes

**Decision.** The generated code always calls DC's recorder, and the mode is read at run time, so one image serves both modes. `mode=:record` is the default: the recorder records every instability, the real body runs, and the run fails at the end with the full list. `mode=:error` records and then throws `TypeInstabilityError` at the call, for debugging. DD warn mode is never used.

**Requirements.**
- `record(site, S, kw, params, T, args, allowed)` is `@noinline`. Its dedupe key is `Tuple{typeof(S), typeof(kw), Val{allowed}}`: types only, never argument values.
- *Inert processes and modules.* `record` first returns `nothing`, without recording or throwing, when `jl_generating_output() != 0` (precompile workers never record instabilities or throw, S2 D46; a workload call there must not touch `site`, which is serialized into the image), or when `jl_get_module_infer` of the site's defining module is 0 (S3.4 call-time inertness; S6a).
- *Fast path.* If the key equals `site.last` (atomic monotonic read), increment `site.hits` atomically. This path takes no lock and allocates nothing. Hit counts are informational; under thread contention they MAY be sharded or capped.
- *Slow path* (`@noinline`), under a `Threads.SpinLock` (a contended `ReentrantLock` may yield):
  - insert the key into the run table;
  - on the first occurrence of a key only, also register the site in DC's live table, capture a raw `backtrace()`, and record the task, thread id, pid, inferred `T` and context;
  - the context is `:generator` when `jl_is_in_pure_context`, `:finalizer` when `jl_gc_is_in_finalizer`, and `:call` otherwise.
- The testset is looked up through `Base.loaded_modules[PkgId(Test)]`, without declaring Test as a dependency. The lookup is skipped in `:generator` and `:finalizer` contexts.
- The recorder never does IO, never logs and never yields. Symbolication happens at exit. Sites register on their first hit at run time, never at precompile time. Pushes into DC state from a precompile worker are lost (`$AUDIT/D03-checking-mode-q7r2/img`).
- *Throw rule.* Throw only if `!allowed && mode === :error`, the context is neither `:generator` nor `:finalizer`, and the site is not a per-image canary. Per-image canaries run in a hook's `__init__` and never throw (S2 D46). The activation self-test's `mode=:error` canary (S3.2) does throw. The exception is DD's `TypeInstabilityError(site.print_name, site.source, args, kw, map(Pair, site.where_names, params), T)`, carrying DD's message.
- *Allowed.* When `checking_enabled()` is false (DD `allow_unstable`), the event is recorded as `allowed`. It is informational and does not fail the run (#103). The README states that `allow_unstable` is process-wide.
- *Generator context.* Count it like any other instability (conflict 5). Never throw there (#11).
- *Canary sites* (`site.canary`) go to the self-test sink. They never reach the verdict. Validation requires that each live image's canary was recorded (S3.2), except for images registered as inference-disabled (O10, S6a).
- *Verdict.* The run fails when at least one non-canary, non-allowed instability exists, in either mode. This is a validation failure inside D02's final status. The D22 summary groups instabilities by definition with:
  - up to 3 signatures, plus "+N more";
  - the first raise site, testsets and counts;
  - a copy-paste line of `unstable=` pair selectors (`:f => "src/x.jl:12"`) for anyone who decides to stop checking them.
- *Descendants.* The recorder exposes new events to D12's flusher through a lock-free counter. The flusher, not the recorder, writes the per-process file.
- *GPU.* The `record` call sits only in the branch that folds away for stable code. Stable kernels compile unchanged. Unstable device functions fail GPU compilation in both modes, as today (conflict 9).
- *Native annotations.* Source `@stable` annotations that DC re-wraps follow DC's mode (S3.3). Tests that assert `@test_throws TypeInstabilityError` belong in `original=` guard files.

**Rationale.**
- Error mode skips the body, so try/catch, `@test_throws`, tasks and finalizers swallow detections (#89, #86).
- Warn mode `@warn`s on every call (`stabilization.jl:198`), and `@test_logs` fails (`$AUDIT/map-q3-k7x2/warnmode.jl`).
- The prototype matched production on 24 of 24 swallow scenarios in record mode (`$AUDIT/swallowed-instabilities-19885`).
- A naive recorder costs 602 ns and 144 B per call. The per-site fast path costs 6-7 ns and 0 B (`$AUDIT/D03-checking-mode-q7r2/trick.jl`, `fast.jl`).
- Generator-time records keep production inference (`gen.jl`).
- On Julia 1.13.2 both context probes work: `jl_is_in_pure_context` is true inside a generator, and `jl_gc_is_in_finalizer` is true inside a finalizer.

**Tests.**
- The 24 swallow scenarios.
- `@test_logs` and `@test_nowarn` pass around unstable calls.
- Generator helpers: production inference is kept, and no throw happens even in `:error` mode.
- Finalizer and task contexts.
- `allow_unstable` gives an `allowed` event.
- The mode switch at run time works without a rebuild.
- An overhead budget: at most 20 ns per call on the fast path, 0 B, and an unchanged stable path.
- Four threads.
- The GPU leg (manual, L40S, D36): a stable kernel compiles, and an unstable one gives `InvalidIRError` in both modes.

**Resolved points.**
- Resolved (default): generator-time records depend on which specializations the image already holds. They are deterministic for a given image and test run. The README and `docs/design.md` document this; no further mechanism is added in 0.2.0.

### S3.1.2 D42 AD transparency

**Decision.** In 0.2.0 the prologue is a single call to DD's `_show_warning` with a DC-owned first argument (S3.1 F3, R7). DD's ChainRulesCore extension (`@non_differentiable _show_warning(::Any...)`) and EnzymeCore extension (`inactive_noinl`), and Mooncake's own `@zero_derivative` rule, make it inactive. DC declares no AD weak dependencies.

**Requirements.**
- The helper takes values and returns `nothing`. Every type computation (`argtypes`, `_promote_op`, `typeof(kw)`) happens inside it.
- No generated AD-visible statement returns a Type.
- When DD's ChainRulesCore extension is loaded in the checked process, DC SHOULD check that `rrule` dispatch for `Tuple{typeof(_show_warning), Site, Vararg}` resolves into that extension. If it does not, the D22 report gets a setup note that AD transparency was lost. Values and detection are unaffected, so this is not a failure.
- README: reverse-mode AD through checked functions behaves as in production, with about 2x residual overhead under Zygote `map`. Allocation and timing tests of gradients still belong in `original=`.

**Rationale.**
- Only the collapsed prologue restores production behaviour: Zygote infers `Tuple{Float64}` in 20 ns. Stock DD and a throw-only rewrite give `Tuple{Any}` in about 9.4 µs (`$AUDIT/D42-ad-transparency-z9k4/e1.jl`).
- On nested checked calls the slowdown drops from 28.96 µs to 20 ns, and on a 1000-element Zygote `map` from 8.74 ms to 14.65 µs (production 6.53 µs) (`e2.jl`).
- The same helper without the rule infers `Tuple{Any}` (`e4.jl`), so the inherited rule is what does the work.
- Without this fix, package code that differentiates its own checked functions reports false instabilities (#111).

**Tests.**
- Contract tier, weekly and against the latest DD: Zygote `@inferred gradient` for scalar, `Type{T}`, where-parameter, `Val`, vararg and nested checked calls.
- ForwardDiff, ReverseDiff, Enzyme and Mooncake give values equal to production.
- An unstable function is detected under Zygote in both modes (`e3.jl`).

### S3.1.3 D43 Type-valued keywords

**Decision.** Type-valued keywords are checked as the singleton `Type{T}` through a gate.

**Requirements.**
- First run DD's own check with `typeof(kw)`, which gives `DataType` for type values and folds at compile time.
- Only if that check fails the site's predicate (the same `Val{L}`), call `keyword_retry` (`@noinline`). It recomputes with `NamedTuple{K, Tuple{argtypes(values(kw))...}}` and uses the singleton result as the verdict.
- If the retry passes, add one *leniency* entry, deduplicated per site and key: site, both keyword NamedTuple types and both inferred types. Leniencies are informational in D22 and never a failure.
- The retry SHOULD memoize per (site, keyword type).
- There is no keyword option for this (O6).
- README: keywords are checked as `Type{T}`, as DD already does for positional arguments. Direct `@inferred` and `@code_warntype` on a keyword call report `DataType` (DD#27, julia#54661). Use `Val{T}` or a positional argument for native parity.

**Rationale.** The idiom appears in about 15 of 561 depot packages, and in constructors and allocators of two internal consumer packages. Native DD flags all of them. A literal-type caller infers concretely in production. A caller that picks the type at run time is still flagged. The gate costs about 120 ns and 0 B when DD passes, where the ungated singleton costs 5.5-13 µs and about 1.9 KB (`$AUDIT/devil-D43-16609/exp6.jl`, `exp7.jl`, `exp8.jl`).

**Tests.**
- The six #21 cases pass and produce leniency entries; `kw_bad` is still flagged.
- A runtime-chosen `T` is flagged at the caller.
- Slurped keywords.
- `union_limit=2`.
- A dynamic call of a keyword function that DD passes allocates 0 B.
- A GPU device case.

### S3.1.4 D23 Long tuples

**Decision.** Argument-type tuples are built at their known size for every arity. This is generic, not GPU-specific.

**Requirements.**
- `argtypes(args::T)` is a DC `@generated` function. For a concrete `T` it emits `tuple(argtype(getfield(args,1)), …, argtype(getfield(args,n)))` with `Expr(:meta, :inline)`. It falls back to `map(argtype, args)` only when `fieldcount(T)` is unknown.
- The same helper builds the keyword types in S3.1.3.
- JLL targets: see O10 and S3.4.

**Rationale.** Base `map` over a tuple of 32 or more elements takes a heap path. With DD's `map_specializing_typeof`, a call costs 2592 B at N=32 and 6416 B at N=64, plus about 10 µs. On an L40S, kernels with 32 or more arguments fail with `InvalidIRError`. The fixed-size form gives 0 B and correct results (`$AUDIT/D23-special-cases-k9w4/longtuple.jl`, `gpu_wide.jl`).

**Tests.**
- CPU, always on: a 36-argument checked function adds 0 B over production, and its unstable variant is recorded.
- GPU tier: out plus 31, 32 and 36 arguments compile and return correct values. `test/gpu` sources point to the checkout (#43).

### S3.1.5 Simulator lines, baremodule-safe code, inner constructors, `Type{<:Type}`

**Requirements.**
- *Simulator lines (F1).* The bug in #13 cannot recur, because no name-based restoration remains.
- *Baremodule (F4).* The prologue uses `GlobalRef`s only, so there is no `!`, `throw` or `map` in generated code.
- *Inner constructors.* A non-curly definition inside a `struct` body is wrapped with `inner_ctor=true` (F6). The marker is emitted inside the struct body. Its D05 record is pushed immediately after the enclosing `struct` statement, never as a non-definition statement inside the struct body. This works for the `where` and keyword forms. Curly inner constructors stay `limitation(parametric_name)`.
- *`Type{<:Type}` (#82).* `argtype(x) = DD.specializing_typeof(x)`, plus `argtype(::Type{X}) where {X} = Type{X}`. Every Type value therefore maps to its singleton, including `DataType` and `Type{Int}`.

**Rationale.**
- Without `#self#` handling, an unstable inner constructor throws `UndefVarError(#self#)` and cannot be waived. With `self=nothing`, it is detected, and `allow_unstable` works (`$AUDIT/D08-default-check-scope-v3n7/e2_ctor.jl`, `$AUDIT/dd-coupling-17901/ctor`).
- For #82, DD maps `DataType` to `DataType`, so `promote_op(emp, …)` gives `Dict{_A,Symbol} where _A`. The singleton gives `Dict{DataType,Symbol}`, which equals production (`$AUDIT/dogfood-orderedcollections-4511/dd_empty.jl`; re-run for this spec on Julia 1.13.2 and DD 0.4.29).

**Tests.**
- The OrderedCollections `empty(d, ::Type{K}, ::Type{V})` repro passes.
- Inner constructors: plain, `where` and keyword forms, plus a curly limitation.
- `baremodule` with no Base import.
- Command literals and `@__DIR__` in anonymous and operator definitions are flagged when unstable.

**Resolved points.**
- Resolved (default): the #82 `Type{<:Type}` singleton handling is adopted as template divergence 8 (S3.1 R9; D21 lists it), although it is not in the owner's O4 parameter list. It matches production on Julia 1.13.2 and DD 0.4.29.

---

## S3.2 DispatchDoctor runtime-helper self-test and drift policy

**Decision.** DispatchCheckup (DC) fails closed when DispatchDoctor (DD) is too old or its helpers have drifted. DC detects drift through:
- an activation self-test;
- per-image canaries in live processes;
- an end-of-run canary;
- scheduled CI against DD main.

DC's semantics are DD 0.4.29 plus the S3.1 R9 divergences. Fixes to DD's runtime helpers reach DC automatically, because DC calls those helpers by reference. Changes to DD's generator are ported by hand.

**Requirements.**
- **Activation check** (O14). Activation errors with a message naming the failing package's version and the remedy when any of these fails:
  - `pkgversion(DD) >= v"0.4.29"`;
  - `DD._Utils.JULIA_OK`;
  - `pkgversion(MacroTools) >= v"0.5.12"`. Resolved (default): this fail-closed floor is adopted in addition to the DD floor, because below 0.5.12 the walker silently reported sites as unsupported (S4, S5 D20). The floor is re-measured after the walker refactor.
- **Activation self-test.** It runs in the activating process before any image is built. It MUST complete in under 1 s warm.
  - (a) Every R1 name is defined, with the method shapes DC calls. `hasmethod` covers `_promote_op(::typeof(Core.kwcall), ::Type, ::Type, ::Tuple)`, the 6-field `TypeInstabilityError` constructor and DC's own `_show_warning(::Site, …)`.
  - (b) Behavioural canaries. They are generated by the template into a DC-owned module created at activation, then called. Each must behave as stated:

    | canary | expected result |
    |---|---|
    | unstable `first(::Vector{Any})` | recorded, inferred `Any` |
    | stable `x + 1` | not recorded (#41) |
    | positional `::Type{T}` | stable |
    | `; T::Type = Float64` | leniency entry, not recorded |
    | `b ? @__DIR__ : 1` | recorded, and `which(...).line` equals the source line |
    | 40-argument function | 0 B added; its unstable twin is recorded |
    | inner constructor | recorded |
    | `mode=:error` | throws a `TypeInstabilityError` whose `showerror` is DD's |
    | `allow_unstable` | `allowed` event |
    | `union_limit=2` | `Union{Float64,Float32}` is stable |

    The canaries record into the self-test sink only.
- On failure, the error names the failing helper or canary and the DD version. It says that DC 0.2.x is validated against DD 0.4.29-0.4.x as listed in the CHANGELOG, and suggests capping DD in the test environment's `[compat]`.
- **Per-image canaries** (D46). Each image's private submodule defines one unstable and one stable canary through the template when the image is built. Its `__init__` runs them only in live processes, never when `jl_generating_output() != 0`.
  - The unstable canary not being recorded, or the stable canary being recorded, is a configuration error: DD drift, inference disabled process-wide (#41), or disabled checks.
  - When `jl_get_module_infer(root) == 0`, including a flag set late in the module body, the canaries are skipped and the report says "inference disabled: nothing checkable in ⟨module⟩" (O10). A late flag is never a configuration error (S6a requirement 3; S3.4).
- **End-of-run canary** in the activating process, before validation. It catches tests that left checks disabled.
- **CI** (D36):
  - per PR: the latest DD release;
  - a weekly `dd-floor` leg pinned to `=0.4.29` (Resolved (default): adopted, S5 D36), so the range floor stays tested once 0.4.30 exists;
  - a weekly cron against DD `main`, running the full template contract suite;
  - a weekly hash of DD's `_stabilize_fnc`, `specializing_typeof`, `ignore_function` and `_promote_op` sources. A changed hash opens a review issue; it is not a test failure.
- **Upstream** (issues filed, nothing waits on them): inner-constructor `#self#`, unqualified `!`, `rmlines` dropping `__source__`, the long-tuple `map`, `Type{<:Type}` (comment on PR #108), the `Expr(:module)` edition argument, the AD prologue shape, singleton keywords (DD#27), and a record/callback hook.

**Rationale.** Simulated DD refactors silently disabled rewrite-based DC while its canary still passed (`$AUDIT/D21-dispatchdoctor-coupling-t5n8`, `$AUDIT/verify-ddinternals-0705c80d`). `Manifest*.toml` is gitignored and CI resolves fresh, so drift reaches users. Five canaries cost 0.019 s to define and 0.089 s to call when warm (`exp/selftest_cost2.jl`).

**Tests.**
- The self-test fails closed against each drift environment (v1, v2, v3b) with a precise message.
- A DD build with `_show_warning` removed: DC still precompiles and imports, and activation fails closed.
- A late `@compiler_options infer=false` fixture passes: its wrappers are inert, its records become `by_design.infer_disabled`, and the report says nothing checkable there (O10, S6a).
- `--compile=min` (the stable canary registers) produces the configuration error.

---

## S3.3 D09 Existing DD annotations

**Decision.** DispatchCheckup (DC) strips DispatchDoctor (DD) `@stable` and `@unstable` annotations in the target's source and re-applies them through DC's template and region rules. Each annotation keeps its own effective union limit. Its mode is overridden by DC's `mode=`. DD's region rules are mirrored exactly.

**Requirements.**
- **Effective union limit** for a source-annotated definition is the first of:
  1. the target's DD preference `dispatch_doctor_union_limit`, or the deprecated `instability_check_union_limit`;
  2. the innermost source `default_union_limit`;
  3. 1.

  This mirrors DD's `get_all_preferred`. Preferences are read with `Preferences.load_preference` keyed by the UUID DD would use (`Base.PkgId(moduleroot(mod)).uuid`). A change therefore invalidates the image. Preferences do not reach extension modules, because their UUID differs, exactly as in DD.

  The `union_limit=` keyword applies only to DC-generated wrappers outside source `@stable` regions (O6).
- **Option parsing** mirrors DD 0.4.29's `parse_options`:
  - only `default_mode`, `default_codegen_level`, `default_union_limit` and the deprecated `enable` and `warnonly` are accepted;
  - any other option, or a non-literal `default_union_limit`, raises DD's error at expansion;
  - mode and codegen options are parsed for validity but never evaluated or honoured.

  The DD-main canary checks that this parser agrees with DD's `parse_options`.
- **Regions**, as verified against DD 0.4.29:
  - (a) A `@stable [opts] begin … end` or `@stable module` region gives its effective limit and origin `source_stable` to every definition inside it, including definitions in files included inside it. The include mapper carries the region context (S3.11 W8).
  - (b) A nested `@stable` does not inherit from the enclosing block. Its own options, or the defaults, apply.
  - (c) `@unstable` (block or definition) hides its contents from implicit wrapping: `unstable_listed` with origin `source_unstable`, and includes inside it are still mapped.
  - (d) An explicit `@stable` inside an `@unstable` region, written inline or in an included file, is still wrapped.
- `default_mode="disable"` never disables DC checking (SymbolicRegression and DynamicExpressions pattern).
- **Out of reach.** Some source `@stable` calls are inside a quote, a non-literal `@eval`, an opaque macro or a function body. They expand natively under the production DD preferences, which DC does not change, so they behave exactly as in production. D44 reports them as `checked` with origin `native`, recognised as `_simulator` methods that DC did not generate. The recorder does not see them.
- Each record carries its origin and its effective union limit.

**Rationale.**
- DD preferences override every `default_*` option. Forcing `union_limit=1` caused #19 (`$AUDIT/dd-coupling-17901/existing`).
- An `@unstable` around an include was ignored (#16, `$AUDIT/transform-review-k7q2/cases/c13_unstableinc`).
- The region semantics are verified in `$AUDIT/D09-existing-annotations-k3m7/nest/run.jl` and `run2.jl`. Preferences not reaching extensions is verified with `Toy2`.
- With the owned template, DC needs no `dispatch_doctor_mode` or `codegen_level` forcing.

**Tests.**
- The #19, #16 and #4 repros.
- A block limit flows through an include.
- A nested `@stable` without options inside a limit-2 block.
- An explicit `@stable` inside `@unstable`, inline and through an include.
- A `default_mode="disable"` block is still checked.
- A preference in LocalPreferences overrides an option, and changing it rebuilds the image.
- An extension annotation ignores the parent's preference.
- An unknown option fails as in DD.
- A native annotation inside a quote is reported with origin `native`.

---

## S3.4 D08 Default check scope and by-design skips

**Decision.** DispatchCheckup (DC) checks every definition that its template accepts, except a fixed set of by-design skips. A by-design skip is either a deliberate opt-out by DispatchDoctor (DD) or the author, or code whose return value Julia discards or never runs in the checked process. Inner constructors stay checked (S3.1.5).

**Requirements.** The by-design reasons, all class `not_applicable` (S3.0):

| reason | rule |
|---|---|
| `by_design.init` | `__init__` in every owned module, extensions included (#15). |
| `by_design.dd_ignored` | DD's `ignore_function` is true for the defined function. The definition is still wrapped, and DD's runtime `ignore_function(self)` decides. The class is decided at evaluation time on the actually defined binding, never by name: a module-local `iterate` is checked (#14, `$AUDIT/D08-default-check-scope-v3n7/e4_shadow.jl`). |
| `by_design.infer_disabled` | `ccall(:jl_get_module_infer, Cint, (Any,), __module__) == 0` at marker expansion, or a flag of 0 on the defining module at finalization (a late flag, S6a requirement 3). The flag is inherited by submodules; a child that sets `infer=true` is checked. Inference is never re-enabled (O10). |
| `by_design.jll_generated` | Sites of the vetted JLLWrappers macros (S6a requirement 1). |
| `by_design.nospecialize` | DD's `has_nospecialize`. |
| `by_design.workload` | Bodies of PrecompileTools `@setup_workload`/`@compile_workload` and SnoopPrecompile equivalents. |
| `by_design.load_time_lambda` | Anonymous functions and do-blocks that appear anywhere inside a top-level statement except as the whole right-hand side of `name = …` or `const name = …`. This includes keyword-argument lambdas such as `sort!(v; by = x -> …)`. They are never wrapped, in either load mode (conflict 13, #117). |
| `by_design.default_constructor` | Compiler-generated constructors at a `struct` statement (the audit only). |

- A skip only removes the wrapper. Include mapping still applies inside skipped `__init__` bodies and skipped modules, so Requires glue stays instrumented.
- Named bindings of anonymous functions (`const f = x -> …`) are wrapped.
- **End-of-module check.** The walker appends to each owned module body one pure record statement: `PRIV.module_end!(@__MODULE__)`, which records the module's infer flag. If inference is disabled at module end but the module holds `checked` records (a late flag), those records are reclassified `not_applicable(by_design.infer_disabled)` at finalization and the report names the module and the flag site. A late flag is not a configuration error (S6a requirement 3 amends D08(4); O10).
- **Call-time inertness.** The `@noinline` recorder host (S3.1.1) first tests `jl_get_module_infer` of the site's defining module. When it is 0, it neither records nor throws, in either mode, so wrappers defined before a late flag behave as production. The stable path is unchanged (S6a requirement 3).
- **JLL targets (O10).** The JLL section specifies how the walker maps the includes generated by JLLWrappers' `@generate_main_file_header` and `@generate_main_file` without a bypass error. The special inference re-enable (`instrumentation.jl:572-576`) is deleted. Definitions in infer-disabled modules are `by_design.infer_disabled`. A target with nothing checkable passes with a report note, not an error. GodelaAMGX_jll's checked test must keep passing.
- An `unstable=` selector that names a by-design site counts as a match, never as unmatched; the entry's state is `redundant` (S4 D10). The old `unstable=(:__init__,)` workaround therefore keeps working.

**Rationale.**
- `jl_get_module_infer` gives A=0, A.Sub=0 and A.SubOn=1. The flag is stored in images and read from `method.module` when inference runs (`e1_infer.jl`, `e3.jl`).
- Re-enabling inference changes behaviour: an empty comprehension's element type becomes `Int` instead of `Any` (`$AUDIT/D23-special-cases-k9w4/jll`).
- PrecompileTools gates its workloads on `jl_generating_output()`.
- DD documents iterate, getproperty and setproperty! as meant to be unstable (`macro_interactions.jl:149-161`).

**Tests.**
- `__init__` in the root, a submodule and an extension (`$AUDIT/transform-review-k7q2/cases/c11_init`).
- A Requires-style include inside `__init__` is mapped.
- A shadowed `iterate` is checked, and `Base.iterate` is `by_design.dd_ignored`.
- An ArgParse-style infer=false module (`$AUDIT/semantics-review-x7q2/run/noinfer`) and an `infer=true` child.
- A late flag (definitions before `@compiler_options infer=false`): wrappers are inert in both modes, records become `by_design.infer_disabled`, and the run passes.
- Load-time lambdas, including the keyword form, do not hang or fail (`$AUDIT/source-load-pkgimage-90d54fc3/k_toplevel_do`).
- An `unstable=(:__init__,)` entry is reported as redundant.
- The JLL fixture passes and reports nothing checkable.

---

## S3.5 D05 Evaluation-time records

**Decision.** DispatchCheckup (DC) learns coverage facts when code is evaluated, not when it is expanded. The walker and markers stay pure. They emit record pushes that run in the same control-flow position as the definition, into a sink in the image's private submodule. The sink is serialized into the package image. Definitions in branches that never run produce no record and are reported as *inactive*.

**Requirements.**
- **No side effects at expansion or mapper time.** The 0.1.x helpers `_record!`, `_excluded!`, `_doctor_canary!`, transform-time records and the expansion-time `Core.eval` are deleted. Every fact becomes emitted code.
- **Sink.** Each image (the root and each extension) has one record sink in its private submodule: the `SINK` constant of S2 D46, which holds both the records and the statement inventory (D46; conflict 3).
  - A push targets the sink of the image's root, through a `GlobalRef` computed at expansion: `moduleroot(__module__)`.
  - An extension never pushes into its parent's sink, because those pushes are silently lost.
  - Records hold only Strings, Symbols, Ints and DC-defined immutable structs, plus the `Site` reference.
- **Record.** It holds site id (crc32c of package-relative file, first line, ordinal and module path), class, reason, origin, module path, name, package-relative file, `[first_line, last_line]` span, effective union limit, matched selector indices, and an evaluation count.
  - Pushes are deduplicated by site id, so a top-level loop increments the count.
  - For top-level definitions the push follows the definition in the marker's output block. The definition is wrapped in `Core.@__doc__`, so docstrings still attach.
  - For inner constructors the push follows the enclosing `struct`.
  - `by_design.dd_ignored` is decided in the push by calling `DD._Interactions.ignore_function` on the defined binding.
- **Statement inventory.** For every walked top-level statement, the walker emits one unconditional push of a literal tuple of all syntactic sites in that statement, including inactive `if` and `@static` branches. Each site carries name, module path, span and selector hits.
  - A site that is in the inventory but has no record is *inactive*.
  - Files that are never walked (unloaded extensions) come from the O6 parse index.
  - O6 validation consumes the records, the inventory and the index.
- **Collection.** Containers are registered with DC by reference per (PkgId, config digest) when the image loads. They are read at flush and finalization, so runtime-defined methods and extensions loaded mid-suite are covered.
  - A missing sink or a digest mismatch fails closed before the tests run (D45/D46).
  - Image builds, cache hits and source-load fallbacks use the same code path.
- Records evaluated into a module that is not owned are dropped. The walker classifies them `informational(foreign_module)` in the inventory.
- **Top-level eval.** `eval`, `Core.eval` and `Base.eval` calls with non-literal arguments get a site record (S3.9). Literal `@eval` bodies are walked (S3.11 W9).

**Rationale.**
- In Compat, 103 of 107 "instrumented" definitions were dead code (#5, `$AUDIT/compat-dogfood-x7k2/repro-deadbranch`).
- Pushes into a target-owned const survive precompilation and cache hits. Pushes into DC or a parent package are lost on image loads only (`$AUDIT/D05-coverage-record-timing-q7x3/sink`).
- A block of the definition plus a push breaks docstrings unless the definition is wrapped in `@__doc__` (`docprobe.jl`).
- A literal `begin` inside a struct body breaks inner constructors (`structprobe.jl`).

**Tests.**
- One fixture with dead branches, an extension, a docstring, a struct, a top-level loop, eval and an inactive `@static` branch. It must give identical records on a fresh image build, on a cache hit and under `--compiled-modules=no`.
- Exclusion keys are classified matched, inactive or absent.
- A digest mismatch fails at load.
- An extension's records stay in the extension's own sink.

---

## S3.6 D44 Method-table audit

**Decision.** In 0.2.0 an audit of owned methods runs at finalization in each process (merged per D12) and backstops the walker:
- evaluation-time records keep authority over reasons, selector intent and spans;
- the audit establishes ground truth on which owned methods exist, and flags every method that no record accounts for.

**Requirements.**
- **Owned set.** The target root, its submodules and its extensions, by PkgId. `Base.package_callbacks` records the load world of each.
- **Enumeration.** One `Base.visit(Core.methodtable)` pass behind the compat module (#80). Each method whose `parentmodule` is owned is mapped to the innermost record or inventory span that contains its (file, line). Methods whose file lies outside the package tree, such as test code running `@eval MyPkg …`, are ignored.
- **Classifier**, applied before a method counts as unaccounted:
  - DC simulators (`_dcsim`) and private-submodule methods;
  - DD-native simulators (`_simulator`), which make their span `checked(native)`;
  - closures and anonymous functions (by type);
  - `@generated` generator methods (`m.generator`), as limitation;
  - macro methods (`#@name`);
  - default constructors at a `struct` statement;
  - forwarders: kwsorters, kwbodies and default-argument methods that share a span with a checked method of the same generic or its kwbody.
- **Outcomes.**
  - A method in the span of a `checked` record is accounted for if it references DC's `Site` or the classifier explains it.
  - A method in the span of an `unstable_listed`, `not_applicable`, `informational` or `limitation` record is accounted for.
  - A method in the span of a `blind_spot` record gives that blind spot its real name.
  - Any other owned method in the package tree is `blind_spot(audit_unaccounted)`, with its real name, signature and `file:line`.
  - Methods added after the load world inside package spans are reported as runtime-defined and count if unaccounted.
  - An opaque-macro or non-literal-eval site whose span produced no unaccounted methods is downgraded to `informational` (S3.9).
- **Consistency assertion** (not a classifier input). Every `checked(dc)` record whose span produced methods has at least one method that references DC's `Site` (`m.roots`, or the IR when roots are absent). A failure is a setup error: template drift.
- **Audit canary.** At activation, the audit runs over a DC-owned fixture module holding one wrapped definition and one method defined by `Core.eval`. It must flag exactly the eval method, or activation fails closed.
- **Cost budget.** Under 0.5 s on StaticArrays-sized targets.

**Rationale.**
- Walker-only coverage misses `include_string` aliases, `Core.include`, `invokelatest(Core.eval)` and top-level eval (#25, #17, `$AUDIT/include-review-29383/aliasbypass`).
- Once records carry spans, the audit gives 0 false positives on StaticArrays: 2643 owned methods, 1153 records. Without spans it gives 53. It also found 17 "instrumented" records inside dead `VERSION` blocks.
- Enumeration takes 15.8 ms warm over 31,293 methods. The IR scan takes 33-84 ms (`$AUDIT/challenge-D44-method-table-audit-m7q4/dump.jl`, `spans.jl`).
- Extension methods report the extension as `m.module` (`e2`).

**Tests.**
- The four-channel bypass corpus is flagged with real names.
- Dead `VERSION` branches.
- An extension method.
- A macro without `__source__`, attributed to the macro's definition line (`macros.jl`).
- Test-defined methods are ignored.
- A StaticArrays-style corpus gives zero false positives (weekly corpus, D26).
- The audit canary.

---

## S3.7 D06 Decorator policy

**Decision.** DispatchCheckup (DC) denies unknown definition decorators by default and uses a vetted, built-in, versioned classification table. There is no user keyword: no `macros=` and no table extension API. An unknown decorated definition is left unwrapped and recorded as `blind_spot(unvetted_decorator)`. The user acknowledges it with `unstable=`.

**Requirements.**
- **Key.** Macros are matched by resolved binding at marker expansion: (`PkgId` of `moduleroot(parentmodule(macro_function))`, `nameof`). A binding that cannot be resolved, or that resolves to a different package (for example a user macro named `@inline`), is unknown.
- **Table** (initial contents; the table version is a D45 input):

| class | macros | effect |
|---|---|---|
| `:both` | Base `@inline`, `@noinline`, `@propagate_inbounds`, `@constprop`, `@nospecializeinfer`, `@inbounds`, `@views`, `@fastmath`; MuladdMacro `@muladd`; SimpleTraits `@traitfn` | wrapped; decorator on simulator and wrapper |
| `:outer` | Memoize `@memoize`; TimerOutputs `@timeit`, `@timeit_debug` | wrapped; decorator on wrapper only (the simulator never runs) |
| `:skip` → `limitation(<reason>)` | Base `@ccallable`, `@generated`, `@assume_effects`, `@kwdef`, `@enum`, `@deprecate`, `@opaque`, `@overlay`, `@consistent_overlay`; CUDA/GPUCompiler `@device_override`, `@device_function(s)`; Unrolled `@unroll`; ZygoteRules `@adjoint`; RecipesBase `@recipe`; KernelAbstractions `@kernel`; DynamicPPL/Turing `@model`; MacroTools `@capture`; Memoization `@memoize` (until verified) | original emitted, named reason |
| `:nondefining` → `not_applicable` | `@deprecate_binding`, `@reexport using …`, logging, `@assert`, `@show`, timing macros, the Base string-literal macros | original emitted |

- DD's built-in `IncompatibleMacro` and `DontPropagateMacro` entries are mirrored by this table, plus D07's transparent and strip classes. DC never reads or writes DD's `register_macro!` table. Scoped registrations in a target, such as Mooncake's, are therefore treated as unknown.
- **Author vouching.** A source `@stable` written directly on a decorated definition, whose effective production mode is not `"disable"`, counts as the author vouching for it. Unknown decorators then get `:both`, as DD does in production. A block-level `@stable` does not vouch.
- **Evaluation-time assertions** for `:both` and `:outer`: exactly one wrapper is defined, and the simulator is defined. A failure is a setup error. Under precompiled images there is no redefinition fallback.

**Rationale.**
- Allow-all broke loading for `@ccallable`, `@unroll` and `@adjoint`, and duplicated registries (#3).
- Today `@memoize` builds 6 caches instead of 3 and falsely flags a stable keyword function. The `:outer` placement matches production (`$AUDIT/D06-decorator-macro-policy-v4n7/scripts/exp1.jl`, `exp2.jl`, `exp4.jl`).
- `@kernel` under `@stable` checks nothing (`exp3.jl`).
- Binding keys tell Memoize from Memoization and reject a fake `@inline` (`exp5.jl`).
- Only Mooncake calls `register_macro!` among 563 depot packages.

**Tests.**
- The 25 survey shapes (`$AUDIT/decorator-survey-1393581b`).
- Memoize cache count equals production.
- `@timeit` creates one section.
- `@ccallable` is a limitation.
- Unknown `@register` is a blind spot, and `unstable=(:h,)` acknowledges it.
- An aliased `@memoize as @memo` resolves.
- A user macro named `@inline` is unknown.
- A directly vouched decorator.

---

## S3.8 D07 Block macros

**Decision.** DispatchCheckup (DC) handles block- and module-wrapping macros through the same built-in table:
- transparent macros are kept outside, and the full walk recurses inside;
- DispatchDoctor (DD) `@stable` and `@unstable` blocks are stripped, and their regions are honoured;
- by-design blocks keep their includes mapped;
- unknown block macros are opaque, but their direct includes are still mapped and their definitions are recorded at their own lines.

**Requirements.**
- **Transparent:** `@muladd`, `@fastmath`, `@inbounds`, `@views`, Reexport `@reexport` (module or `begin`), PrecompileTools `@recompile_invalidations`, `@static`, Distributed `@everywhere`, `Core.@doc`.
  - The walker matches by name.
  - It emits `@_block(expected_binding, original_expr, transformed_expr)`. At expansion this returns `transformed_expr` if the binding matches the table, and `original_expr` otherwise. The fallback maps direct includes only and records `blind_spot(opaque_macro)`.
  - Each inner definition is recorded with its own line and module. `@reexport module` goes through the module transform.
- **Strip:** DD `@stable` and `@unstable` (S3.3 region rules, conflict 6). The region context travels through every include mapped inside the region. The innermost region wins.
- **By design** (`not_applicable`): PrecompileTools workloads, SnoopPrecompile equivalents, and the TestItems/ReTestItems `@testitem`, `@testsnippet`, `@testmodule` and `@testsetup` family. Includes inside them are mapped. Definitions inside never count as selector matches (#105). The vetted JLLWrappers macros are also in this class, handled as S6a requirement 1 specifies (`by_design.jll_generated`).
- **Opaque** (default):
  - map direct `include` calls;
  - record each syntactically visible named definition inside as `blind_spot(opaque_macro)` with its own line;
  - lambdas and do-blocks inside are not counted;
  - a macro with no visible definitions gets one site record, which the audit settles (S3.6);
  - the include observer (D46) stays the fail-closed backstop, and its error names the opaque macros seen in that module.
- There is no `:expand` class, because there is no user keyword.

**Rationale.**
- Outer rewriters keep their semantics when kept outside. `@views` in 1.13 expands nested markers first, which F4 makes safe (`$AUDIT/D07-block-wrapping-macros-q4n8/sem.jl`).
- Unknown block macros are common: 57 of 561 packages use PrecompileTools workloads, and SymbolicUtils and Symbolics wrap their includes in `@recompile_invalidations` (`survey.jl`). An error default would break them.
- Opaque-but-mapped exits 0 where 0.1.x failed with a bypass error (`report_ToyPT_*.toml`).

**Tests.**
- `@muladd` around an include (Trixi-style, `$AUDIT/decorator-survey-1393581b/pkgs3/ToyBlock`).
- `@fastmath`, `@views` and `@inbounds` blocks.
- `@reexport module` with an include.
- A DD block with an include and a limit.
- `@unstable` around an include.
- `@recompile_invalidations`.
- An unknown macro with an include.
- `@setup_workload` produces no noise.
- A binding mismatch falls back to opaque.

---

## S3.9 D11 `require_all` and record classes

**Decision.** `require_all=true` means "nothing escaped classification". It fails the run when any `blind_spot` is not acknowledged by `unstable=`. Listing a definition that DispatchCheckup (DC) cannot check acknowledges it (O6). Resolved (default), the D11 reading: only blind spots not listed in `unstable=` are counted. DD limitations are reported with their locations and counts, and are never counted.

**Requirements.**
- **Class membership** follows S3.0. The reason codes are closed enums, documented in the D22 schema.
- **`informational`:**
  - nested closures of every form (`->`, `do`, `local` functions, `:generator`, `:comprehension`, `:typed_comprehension`, `:flatten`), with the reason "outer return checked" (#72);
  - foreign-module definitions;
  - runtime includes that ran natively.
- **`not_applicable`:**
  - macro definitions;
  - non-defining macros;
  - quoted templates (#73);
  - runtime `eval` inside function bodies (the site itself; methods it creates fall to the audit);
  - test-only bodies;
  - every `by_design.*` reason.
- **`limitation`:** DD declines (`parametric_name`, `incompatible_name`) and the table's `:skip` entries.
- **`blind_spot`** has four sources, each attributed to a *named* method or definition, so `unstable=` grammar (a)-(d) can acknowledge it:
  - (i) unvetted decorator definitions;
  - (ii) named definitions inside opaque macros;
  - (iii) unaccounted methods in an opaque macro's span, or methods created by non-literal top-level eval, found by the audit;
  - (iv) other audit-unaccounted methods.

  A non-literal eval or opaque-macro site that defined no unaccounted owned method is downgraded to `informational`.
- An acknowledged blind spot becomes `unstable_listed` with `acknowledged = "blind_spot"`.
- **Failure** is raised at finalization as a validation failure inside D02's final status. The D22 summary lists each blind spot with its package-relative `file:line`, real name and a copy-paste `unstable=` pair, and prints per-reason counts for the limitation class and the other classes; the D22 report also lists each limitation with its package-relative `file:line` and reason. Only unacknowledged blind spots fail the run.
- Literal `@eval` bodies are walked (S3.11 W9). Only non-literal eval remains a potential blind spot.
- Records missing from an image, through the sink or digest checks, make `require_all` fail closed.

**Rationale.**
- Counting DD limitations left about 78 counted gaps on DataStructures and about 207 on StaticArrays. Under the tiered model, Combinatorics, Compat, OrderedCollections, Accessors and StaticArrays have 0 blind spots, and IntervalSets has 1 (`@recipe`, now a table entry) (`$AUDIT/D11-require-all-k4w9/classify.py`).
- Walking literal `@eval` turned 22 gaps on DataStructures into 28 checked methods, with 265 of 265 tests passing (`dc/`).

**Tests.**
- Rewrite the 0.1.x spec tests: the strict-skip closure test becomes informational, and the `v_str` opaque test becomes non-defining.
- An unvetted decorator fails, then passes once listed.
- An opaque `@delegate`-style macro is a blind spot with real names.
- A non-literal eval that defines a method fails, and one that defines nothing passes.
- `@nospecialize` and `@generated` never fail.

**Resolved points.**
- Resolved (default): the owner's "eval of non-literal code" class is read through the audit. A non-literal eval site that defined no unaccounted owned method is downgraded to `informational`; one that did is a `blind_spot` attributed to the methods it created.

---

## S3.10 Walker decision order and `unstable=` emission (O6)

**Decision.** The `@_check` marker decides each definition's fate at emission time, in a fixed order. A definition matched by `unstable=` is never wrapped: DispatchCheckup (DC) emits the original expression, and production code runs.

**Requirements.**
- **Decision order** at marker expansion, inside `__module__`. The first rule that matches wins:
  1. `__module__` is not owned → original; `informational(foreign_module)`.
  2. An `unstable=` selector matches → original; `unstable_listed`, with the selector indices. If rule 4, rule 6 or a `:skip` decorator would have classified the site, the report notes "redundant (would be ⟨class⟩)". If rule 5 would have made it a `blind_spot`, the record carries `acknowledged = "blind_spot"` instead (S3.9).
  3. Inside a source `@unstable` region, and not explicitly `@stable` → original; `unstable_listed(source_unstable)`.
  4. Infer disabled, `__init__` or `@nospecialize` → original; `not_applicable(by_design.*)`.
  5. Decorators (S3.7): `:skip` gives limitation; unknown and not vouched gives blind_spot; otherwise collect placements.
  6. Template declines (R4) → limitation.
  7. Template → `checked`. DD-ignored is settled at evaluation time.
- **Selector matching** uses only the D45 compile-time selector table and the marker's literal facts:
  - (a) bare `:foo` matches the written final name in any owned module, whatever the written qualifier;
  - (b) an owned-qualified selector requires `string(__module__)` to equal the prefix;
  - (c) a foreign-qualified selector matches the written callee spelling, or the callee resolved at emission time. A value that is a Function, or whose `unwrap_unionall` is a DataType, maps to its owner (`parentmodule.nameof`). Anything else, such as a Union alias, falls back to the spelling (#54);
  - (d) `:foo => "src/file.jl:LINE"` requires the written final name to be `foo`, the package-relative file to match, and `LINE` to be the site's first line: its own first `LineNumberNode`, which equals DD's `source_info` and production `Method.line`.

  Matching inside literal `@eval` bodies happens when the eval'd marker expands, after interpolation, so interpolated names match.
- **Emission of a match.**
  - The original definition is emitted exactly as written, after S3.11 include mapping of its default-argument expressions.
  - There is no simulator, no prologue and no `@__doc__` change.
  - It is followed by the record push.
  - A definition carrying its own explicit source `@stable` keeps that annotation, so DD's native check stays and DD expands it under production preferences, exactly as in production: DD's `@unstable` is a no-op that only hides code from implicit wrapping, and an explicit author-written `@stable` still applies.
  - A member of a source `@stable` block that is listed in `unstable=` is emitted unwrapped.
- Matches count only from evaluation-time records. Inactive and absent classification and the error and note texts are owned by the O6 API section, using S3.5's inventory and the parse index.

**Rationale.** Exclusion must really unwrap code so that it works as an escape hatch: for wrapper-caused failures, for AD, and for decorators. Syntactic matching at emission time is independent of load order (#6, #24, #48, #53).

**Tests.**
- Each grammar form (a)-(d).
- A `Base.getindex` selector against `import Base: getindex`.
- `:..` and `:(==)`.
- A selector inside a dead branch is inactive.
- One in an unloaded extension is inactive.
- A typo errors with candidates.
- A bare name matching two modules gives a note.
- An `@eval`-interpolated name matches.
- An explicit source `@stable` listed in `unstable=` keeps its native DD check.
- A listed member of a source `@stable` block is emitted unwrapped.
- A Maybe{T} Union alias (`$AUDIT/excl-x7k2/names5-unionalias-crash`).

**Resolved points.**
- Resolved (default): for a listed definition that carries its own explicit source `@stable`, DD's native check stays, as in production. DD's `@unstable` is a no-op that only hides code from implicit wrapping, and an explicit author-written `@stable` still applies. O6's "NOT checked at all" is therefore read as "DC adds no check": DC emits no wrapper, simulator or prologue for it. Members of a source `@stable` block that are listed in `unstable=` are emitted unwrapped.

---

## S3.11 Syntax-core walker fixes

These requirements apply to the kept syntax core of DispatchCheckup (DC) (D01). Each lands with its repro as a regression test (D26).

- **W1 `global` and `local` (#2).**
  - `global f(…) = …` in let, for, begin or struct-adjacent top-level forms: the marker gets `global_decl=true` (F7), so the simulator is also global, which the for-loop form needs.
  - A marker is never placed directly under `:global` or `:local`.
  - `local f(…) = …` is a nested closure, `informational`.
  - Fixtures: `$AUDIT/transform-review-k7q2/cases/c01_global`, `$AUDIT/map-q3-k7x2/glob3.jl`, `glob4.jl`, plus let, local, for-loop and struct-body forms. This spec's prototype verified the for-loop and let forms on Julia 1.13.2.
- **W2 Line numbers (#18).**
  - A site's line is the definition's own first `LineNumberNode`, including under `@doc` and other macrocalls.
  - Field lines inside struct bodies are tracked.
  - The span is from that line to the maximum line inside the definition.
  - No line node is ever prepended to a definition that is left unchanged (`$AUDIT/transform-review-k7q2/cases/c08_docline`).
- **W3 Extension identity (#23).** `owned(mod)` is decided by PkgId (Terms). It is used by the walker, the observer, the audit and the selectors (`$AUDIT/excl-x7k2/extcollide`).
- **W4 Union aliases (#54).** Guard every `parentmodule` and `nameof` on a resolved value with `value isa Function || unwrap_unionall(value) isa DataType`. Otherwise fall back to the written spelling.
- **W5 Include rules** (conflict 21; #7). An include evaluated into an owned module is mapped whatever its path, and its path is listed:
  - while an image is built;
  - while the target is source-loaded.

  A runtime include from package functions is mapped only if the file is inside the package root and the destination is owned. Otherwise it runs natively and is `informational`. Includes into modules that are not owned are ignored.
- **W6 Local `include` bindings (#27).** The prepared-include helpers receive the callee value. They return the original arguments unchanged unless the callee is `Base.include`, `Base.include_string`, a `Base.IncludeInto` or the module's own `include`. Fixtures: keyword, positional, local and `include_string` forms (`$AUDIT/semantics-review-x7q2/run/includekw`, `$AUDIT/include-review-29383/localinc`).
- **W7 First-class include (#55).** A bare `include` or `include_string` in value position (`include.(fs)`, `foreach(include, fs)`, `map(include, …)`, `invokelatest(include, f)`, or `const inc = include`) is replaced with a prepared mapped-include callable bound to `@__MODULE__`. An unsupported form raises an actionable error naming its line (`$AUDIT/include-review-29383/bcast`).
- **W8 Include region context.** The prepared include carries the literal region context (S3.3) and the walker options into the included file's mapper. The mapper is a DC-defined callable, never a closure in a shim (D46).
- **W9 Literal `@eval`.** `@eval expr` and `@eval M expr` with a literal body (a quote, a block or a definition, possibly with `$` interpolations) are walked inside the quote. Markers inside survive quoting and expand after interpolation. `@eval $ex` and `eval(ex)` with a non-literal argument are not walked (S3.9).
- **W10 Quoted templates (#73).** Definition detection stops at `:quote` but descends into `:$` interpolations (`$AUDIT/dogfood-simpletraits-17683/repro-quoted-def`).
- **W11 Comprehension closures (#72).** `:generator`, `:comprehension`, `:typed_comprehension` and `:flatten` count as nested closures (`informational`).
- **W12 Module expressions (#100).** Read `Expr(:module)` as `args[end-1]` (name) and `args[end]` (body), which is version-agnostic. Never index `args[2]` or `args[3]`.
- **W13 Load-time lambdas.** Only the whole right-hand side of a statement-level `name = …` or `const name = …` is a named binding (S3.4). This fixes the keyword-lambda misclassification at `instrumentation.jl:817-826`.
- **W14 Marker literals.** Marker arguments are literals or `GlobalRef`s. Walker output contains no `ref` syntax and no bare operator symbols (F4; D07 `@views` hazard).
- **W15 Empty generics and signatures.** `function f end` is left unchanged and gets no record. Default-argument and `where`-bound expressions are mapped as call sites. A declaration's call-shaped signature is never treated as a call (kept from 0.1.x).
- **W16 Index hygiene.** The O6 parse index follows literal includes from the entry and the extension entries. It checks `ext/Name/Name.jl` before `ext/Name.jl` (or calls `Base.find_ext_path`, #58), uses byte-safe path tests, and skips unreadable directories with a report note. This is the residue of #57, #63 and #29.

---

## S3.12 Straightforward-fix disposition (walker and checking)

| fix | disposition |
|---|---|
| #2 global/local | W1 (P2) |
| #7 runtime include | W5 (P2, with D46 observer) |
| #13 simulator restore | moot: the template keeps lines (F1) |
| #18 line numbers | W2 (P2) |
| #23 extension identity | W3 (P1 seam) |
| #26 include observer | D46 owned-module scoping; walker side W5 |
| #27 local include | W6 (P2) |
| #41 stable canary | S3.2 per-image canary pair (P2) |
| #54 Union alias | W4 (P2) |
| #55 first-class include | W7 (P2) |
| #56 optional include | moot under D13: originals are included natively, and Base raises SystemError |
| #57/#63/#29 tree walk | moot under D13 (no tree copy); hygiene kept for the parse index (W16) |
| #58 extension entry lookup | W16 for the index; the shell uses `Base.find_ext_path` (D13) |
| #65 `_generic_name` scan | moot: syntactic matching (S3.10) |
| #72 comprehension closures | W11 (P2) |
| #73 quoted templates | W10 (P2, together with S3.5 top-level eval) |
| #75/#120 DD warnings | moot for DC-wrapped and re-wrapped annotations, because DD's `_stable` never runs. Native out-of-reach annotations expand as in production; their "no compatible functions" warnings are dropped from the reprinted build output like any other (S2 D04). |
| #78 canary leak | private submodule (D46); S3.2 |
| #85 skip reasons | R4 reasons and S3.0 reason codes (P2) |
| #100 Expr(:module) | W12 (P2) |
| #80 Base internals | `jl_get_module_infer`, `jl_is_in_pure_context`, `jl_gc_is_in_finalizer`, `Base.visit` and `Core.methodtable` sit behind the compat module, with a smoke test each |

---

## S3.13 Phasing (D01)

- **P1 (shell and seam, walker frozen).** Typed config. The private submodule sink and its digest (S3.5 containers). Marker purity: move every expansion-time side effect into emitted pushes, keeping the 0.1.x DD-expansion path temporarily. W3.
- **P2 (one PR per walker policy).** In order:
  1. the template: S3.1 with the D42 prologue, D23, S3.1.5 and the D43 gate, initially throwing (error semantics);
  2. S3.2 self-test and canaries;
  3. D05 evaluation-time records and inventory;
  4. D08;
  5. D09;
  6. D06/D07 table;
  7. S3.10 emission and selectors;
  8. D11 classes;
  9. W1, W2 and W4-W16.
- **P3.** D03 per-site recorder with record mode as the default; D44 audit; real-package corpus (D26).

0.2.0 ships after P3. Task order, numbering and effort follow S5's D01 phase plan where the two lists differ; this list gives the checking-side content only.

## S3.14 Resolved points (summary)

This section has no remaining open points. Each former open point is settled as follows.

1. Resolved (default): the #82 `Type{<:Type}` singleton is adopted as template divergence 8, beyond the owner's O4 parameter list. It matches production on Julia 1.13.2 and DD 0.4.29 (S3.1.5).
2. Resolved (default): `unstable=` on a definition with an explicit source `@stable` keeps DD's native check, as in production. Members of a source `@stable` block that are listed in `unstable=` are emitted unwrapped (S3.10).
3. Resolved (default): non-literal eval and opaque-macro sites are settled by the audit: they are downgraded to `informational` when no unaccounted methods exist (S3.9). `require_all` counts only blind spots not listed in `unstable=`; DD limitations are reported with locations and counts, never counted.
4. Resolved (default): a block-level source `@stable` does not vouch for unknown decorators (S3.7). Under a production-active block, DC therefore checks less than production for those definitions. This is a documented D07 risk, and `unstable=` acknowledges the resulting blind spots.
5. Resolved (default): #77, methods with non-specialized `Function` or `Type` arguments still run inference on every call (about 10x slower). It is documented, with no wrapper-only fix in 0.2.0.
6. Resolved (default): generator-context records depend on which specializations the image holds. This is documented (S3.1.1).
7. Resolved (default): the JLL include mapping is owned by the JLL section (O10, S6a). This section fixes only the classification.

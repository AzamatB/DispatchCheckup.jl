# S2 Architecture

Normative for DispatchCheckup (DC) 0.2.0 on Julia 1.13.x. This section covers the process model, environment derivation, overlay, load mode, persistent state, config transport, image hooks, descendant processes, integrity checks, target cardinality, interactive refusal, path resolution, and the reproduction of flags and environment in spawned processes. The walker, template and recorder (S3), the user contract, messages and report schema (S4) and the JLL policy (S6a) are referenced, not restated. "Must" and "should" are normative. Evidence is cited as `$AUDIT/<directory>`, where `$AUDIT` is the maintainer's local review archive (not part of this repository; S1 conventions).

**Terms used in this section** (they refine the S1 glossary):

| term | meaning |
|---|---|
| owner | the activating process (normally the `Pkg.test` test process) |
| member | a descendant process that loads the instrumented image under the owner's run |
| private root `R0` | `DISPATCH_CHECKUP_DEPOT`, else `<DEPOT_PATH[1]>/compiled/v1.13/.dispatchcheckup` |
| key dir `K` | `R0/v1/<Name>-<uuid8>-<crc32c8>/`: one per (name, uuid, realpath of the checkout root), layout 1 |
| overlay `O` | `K/overlay/`: the `Project.toml` copy plus the shims (D13) |
| compile depot `P` | `K/depot/`: the only depot that ever receives instrumented images from the up-front build |
| injected env `M` | `K/env/<hash>/`: the derived environment prepended to `LOAD_PATH` (D24) |
| run dir `R` | per-run directory named by `DISPATCH_CHECKUP_RUN`: a `mktempdir()` created at ACTIVATE step 4 and realpath'd (#52); Base's temp cleanup removes it after DC's atexit hooks (D30 rationale) |
| U | the user's depots, in pre-activation `DEPOT_PATH` order |

S1 calls the whole of `R0` the "private depot". This section separates `P` from `O` because their placement relative to each other matters for cache reuse (D17+D47 `@depot` relocation point, resolved by default to the sibling layout).

---

## Component diagram

```
OWNER (test/runtests.jl, after `import DispatchCheckup`)
  dispatch_doctor(:MyPackage; ...)
    Activation ── Options (pure) ─────────────► RunConfig = (CompileConfig, RuntimeConfig)
       │          Compat (all Base/DD internals, one smoke test each)
       │          SelfTest (DD runtime helpers)
       │          Snapshot (ENV, LOAD_PATH, DEPOT_PATH, DL_LOAD_PATH, project, pwd, ARGS, flags)
       ├─► Store ───── R0/v1/K/{key.toml, stamp.toml, overlay/=O, depot/=P, env/<h>/=M, report.toml}
       ├─► EnvDerive ── Base resolvers over the user's load path ──► M (Project, Manifest, LocalPreferences)
       ├─► Overlay ──── Project.toml copy + entry shim + extension shims ──► O
       ├─► RunDir ───── R/{state.toml, proc/*.toml, build-failures/*.toml, guards.toml}
       ├─► Build ────── DEPOT_PATH=[P; U] ─► Base.Precompilation ─► BUILD WORKERS (kind B)
       │                                                               shim ─► DC._load_original
       │                                                               ─► Walker + Template (S3)
       │                                                               ─► hook module #DispatchCheckup baked in
       │                                                               dependent/extension workers (kind W)
       └─► atexit: Reaper (registered first), Finalizer (registered second, runs first)
  using MyPackage ─► Base loader: M ─► O shim path ─► image in P ─► hook __init__ (kind O) ─► Collector
  checked call ─► template wrapper ─► DD runtime helpers ─► Recorder ─► Collector ─► R/proc/<own>.toml
MEMBERS (kind M: Distributed, Malt/ParallelTestRunner, ReTestItems, run(julia)) ── exported env
  ─► same image from P ─► hook __init__ ─► R/proc/<host>-<pid>-<rand>.toml (write-through)
FINALIZER (owner atexit)
  merge R/proc ─► audit (D44) ─► validate ─► report (S4) ─► GuardRunner ─► GUARD CHILD (kind G)
                                                             julia_cmd + flag table --eval <Base-only bootstrap>
                                                             original= files into Main, original target from U
```

The shell–walker seam (D01) is two typed values. `CompileConfig` is read in build workers from the D45 preference and handed to the walker; it is the walker's only configuration input. The record channel is the hook module's `SINK`, which the walker fills with evaluation-time records (D05) and the collector reads by reference. The walker never touches `ENV`, `R`, the report or the environment.

Besides the source and `CompileConfig`, the walker receives the image identity from `_load_original` (D13): its arguments `id`, `target` and `original` (the entry realpath), plus `root`, which it derives. `root` is the realpath of the nearest ancestor directory of `original` that holds `Project.toml` or `JuliaProject.toml`, which is the checkout root for the target and its extensions alike. Ownership needs no extension list, because it is decided by PkgId (S3 W3). These four values go into the hook's `IMAGE` (D46). Transient build state replaces 0.1's `InstrumentationContext` registry: expected and observed includes and collected failures. It lives in one per-process DC value that `_load_original` creates, and it never enters an image. 0.1's snapshot and overlay roots are gone, so the mapper includes original paths unchanged.

**Seam types** (P1.2). The field sets are normative; representations may vary.

```julia
struct CompileConfig                  # decoded from the D45 table; immutable, stored in each image
    schema::Int                       # transport schema (1)
    rules::Int                        # matching-rules/template/macro-table version (S3.1 R3)
    unstable::Vector{String}          # canonical selector spellings, sorted, unique (S4 D29)
    union_limit::Int                  # >= 1; DC-generated wrappers only
    codegen_level::String             # "debug"
    digest::UInt32                    # crc32c of the canonical table (D45)
end
struct RuntimeConfig                  # R/state.toml [runtime]; never in an image (D45)
    mode::Symbol                      # :record or :error
    report::Union{String,Symbol,Bool} # absolute path, :default or false
    require_all::Bool
    original::Vector{String}          # absolute realpaths, in order
end
struct RunConfig; compile::CompileConfig; runtime::RuntimeConfig; end
```

- **Reaching the config and the sink.** Generated code never names a path, a run or `R`; 0.1's per-marker `config_file` argument (45 uses in `instrumentation.jl`) is removed. `_load_original` decodes `CompileConfig` once and passes it to the walker. The walker splices it as `const CONFIG` into the private submodule it inserts (D46). After the ownership check (S3.10 rule 1), every marker and prepared-include call finds that submodule as `getglobal(Base.moduleroot(__module__), Symbol("#DispatchCheckup"))` at expansion or call time and reads `CONFIG` and `SINK` there. If the submodule is missing, that is a setup error naming the module. The same lookup serves runtime includes and literal `@eval` bodies in live processes.
- **`RecordSink`** is a DC-defined mutable struct with `records::Vector{Record}` (S3.5 fields), `inventory` (S3.5; P2.2) and `module_ends` (S3.4; P2.4). Pushes take a per-process DC lock. Its contents are only Strings, Symbols, Ints, DC immutable structs and `Site` references, so it serializes into the image. `Site` and the template inputs (`SiteFacts`, `TemplateOpts`) land with the template in P2.1 (S3.1).

---

## Source layout (`src/`)

`src/` should be split one component per file, as below. File names are not API. The constraints are normative.

| file | contents | lands |
|---|---|---|
| `DispatchCheckup.jl` | the module, `public dispatch_doctor`, the docstring, and `include`s of the files below; nothing else at top level. **Must not** contain the literal `__precompile__(false)` (D30). | P1.2 |
| `compat.jl` | `module Compat`: one function per Base or DD internal (D24, D46, D18, D15, S3.12 #80), each with a smoke test | P1.2 |
| `types.jl` | the seam types above, `Record`, `RecordSink`, and TOML encode/decode of the D45 table and `state.toml` | P1.2 |
| `options.jl` | `dispatch_doctor` methods; pure validation and normalisation (S4 D29, D15); `unstable=` parsing and canonical spellings | P1.4 |
| `activation.jl` | S4 state machine, window and floor checks, ACTIVATE, rollback, JOIN, banner | P1.2 (window and floor checks), P1.4 (rest) |
| `snapshot.jl` | D18 snapshot and flag table | P1.4 |
| `store.jl` | `R0`/`K`, `key.toml`, stamps, GC, atomic writes, the path-identity helper (#52) | P1.3 |
| `environment.jl` | D24 derivation of `M` (the kept parts of 0.1's file) | P1.3 |
| `overlay.jl` | D13 shims | P1.3 |
| `build.jl` | D04 up-front build, output capture, post-build and load-mode assertions | P1.3 |
| `hook.jl` | D46 private-submodule generation, `_load_original`, `_hook_init`, build gate, include observer, identity and leak callbacks | P1.2 (submodule generation and the `CONFIG`/`SINK` lookup), P1.3 (rest) |
| `rundir.jl` | `R`, `state.toml`, record files, flusher, merge (D12) | P1.4 (files and merge P3.2) |
| `instrumentation.jl` | the walker syntax core (D01), frozen in P1 except for the seam (S5 P1.2) | kept |
| `selftest.jl` | S3.2 self-test and canaries; the D44 audit canary | P1.2 (most canaries P2.1, audit canary P3.3) |
| `finalizer.jl` | D30 finalizer and validation | P1.4 |
| `guards.jl` | D18/D50 command builder and Base-only bootstrap text | P1.5 |
| `report.jl` | D22 report and console summary | P1.4 (schema v1 P3.4) |
| `template.jl` | O4 template, `argtypes`, R7 `_show_warning(::Site, …)` behind the R8 guard; Apache-2.0 SPDX header (D38) | P2.1 |
| `macrotable.jl` | D06/D07 table | P2.3 |
| `selectors.jl` | O6 parse index, matching, three-stage validation | P2.6 |
| `recorder.jl` | D03 recorder (no IO, no logging) | P3.1 |
| `audit.jl` | D44 | P3.3 |

- Base internals are named only in `compat.jl`. DD internals are named only in `compat.jl`, in `template.jl` and, until P2.1, in the frozen walker's DD-output rewrites.
- Code baked into images (`hook.jl`, `instrumentation.jl`, `template.jl`) derives no path from `@__DIR__` (D04).
- The text that detects `__precompile__(false)` in an original lives in `overlay.jl`, never in the entry file.

---

## End-to-end walkthrough: a checked `Pkg.test` run

Setup: a CI checkout at `/work/MyPackage`, test dependencies in `[extras]`/`[targets]`, and `test/runtests.jl` starting with:

```julia
import DispatchCheckup
DispatchCheckup.dispatch_doctor(:MyPackage; unstable = (:foo, :bar), original = ("test_guards.jl",))
```

1. **Pkg.test.** It resolves the sandbox and precompiles everything into `U` (production caches). It then starts the test process as `julia --startup-file=no --warn-overwrite=yes … --eval <gen_test_code>` with `JULIA_LOAD_PATH="@:/tmp/jl_X"` and `JULIA_PROJECT` unset. The eval code sets `DEPOT_PATH`/`DL_LOAD_PATH` in-process, `cd`s to `test/`, sets `ARGS` and includes `runtests.jl`.
2. **`import DispatchCheckup`.** It loads DC (and with it DispatchDoctor (DD), MacroTools, Preferences, TOML) from production images. Nothing else happens: DC's `__init__`, if any, must not touch `ENV`, `LOAD_PATH`, `DEPOT_PATH` or files.
3. **Classification** (S4 state machine). The arguments are valid; there is no guard marker; the process is non-interactive; Linux, Julia 1.13.2, DD 0.4.29 with `JULIA_OK`, MacroTools 0.5.16 (at least the 0.5.12 floor); no previous call; `DISPATCH_CHECKUP` unset. The run is FRESH. Preconditions: MyPackage is identified from `/tmp/jl_X/Project.toml`, it is not in DC's closure, it is not loaded, there are no Distributed workers, and `test/test_guards.jl` exists.
4. **Snapshot** (D18). `ENV` (with `JULIA_LOAD_PATH="@:/tmp/jl_X"`), `LOAD_PATH=["@","/tmp/jl_X"]`, `DEPOT_PATH=[~/.julia, <bundled>…]`, `active_project(false)=nothing`, `pwd=/work/MyPackage/test`, `ARGS=[]`, `PROGRAM_FILE=""`, the flag table (including `warn_overwrite=1`), and `isprecompiled(MyPackage)=true`.
5. **Store** (D17+D47). `K=~/.julia/compiled/v1.13/.dispatchcheckup/v1/MyPackage-5b1e2a7c-9d04c3e1/` is checked against `key.toml` and its stamp is refreshed. Stale keys are garbage-collected. `O` is (re)written only where bytes differ.
6. **Derive `M`** (D24, D45) from Base's resolvers: the target is under `[extras]` and its record points at `O`; the closure is copied from wherever Base locates each package; `LocalPreferences.toml` holds the merged user preferences plus the `[MyPackage] dispatch_checkup` table. `M` is written once under its content hash.
7. **Run dir.** `R` is created (realpath'd) with `state.toml`, the report placeholder `status="incomplete"` is written, and `ENV["DISPATCH_CHECKUP_RUN"]=R` is set.
8. **Build** (D04). Pin the active project to `/tmp/jl_X/Project.toml`, `pushfirst!(LOAD_PATH, M)`, set `DEPOT_PATH=[P; U]`, then run `precompilepkgs` over the environment plus the explicit extension ids, with output captured. Build workers (kind B) run MyPackage's shim, which walks the original files and bakes the hook module and the records into the image. Dependents rebuild into `P`, and their workers (kind W) run the hook's identity rewrite and preference record. Finally `DEPOT_PATH=[U; P]`. The filtered output is reprinted and the post-build assertion passes.
9. **Arm.** Install the include-leak callback for `test_guards.jl` and the identity callback. Export `JULIA_LOAD_PATH="M:@:/tmp/jl_X"`, `JULIA_DEPOT_PATH=":P"` and `JULIA_PROJECT=/tmp/jl_X/Project.toml`. Call `Base.exit_on_sigint(true)`, register the reaper and then the finalizer, set `DISPATCH_CHECKUP="checked"`, print the one-line banner and return.
10. **`using Test, MyPackage`.** Base locates MyPackage through `M` at `O/src/MyPackage.jl` and finds the image in `P` (it scans every depot). The hook's `__init__` (kind O) sets `pathof` to `/work/MyPackage/src/MyPackage.jl`, registers `SINK` by reference, installs the include observer and runs the canary. The identity callback sees the registration.
11. **Suite.** Checked calls run through the template wrapper. In `mode=:record`, an unstable call records once per site and signature, then runs the real body. `get(ENV,"DISPATCH_CHECKUP","")=="checked" || include("test_guards.jl")` skips the guards. A ReTestItems worker inherits the exported env, loads the same image (kind M) and appends to its own `R/proc` file.
12. **Exit.** The suite ends with code 0. Hooks run LIFO: hooks the suite registered later run first (for example Distributed's `terminate_all_workers`), then DC's finalizer, then the reaper, then Base's temp cleanup.
13. **Finalizer.** The end-of-run canary passes. The finalizer merges two process files, runs the audit, and validates: identity and load mode pass, `:foo` and `:bar` matched, and one instability `foo2(::Float64)` was recorded, so validation fails. It writes the report with guards pending, flushes, and runs `GC.gc(true)`. The guard child then starts: `julia_cmd() --warn-overwrite=yes --eval <bootstrap>` with `ENV` = the snapshot minus `DISPATCH_CHECKUP*`, plus `DISPATCH_CHECKUP_RUN="guard:<pid>"` (with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` at their pre-activation values), cwd `test/`, and `LOAD_PATH`/`DEPOT_PATH` restored. Inside `@testset "original: test_guards.jl"` it loads MyPackage from `U` (the production cache) and passes, exiting 0. The finalizer writes the final report atomically, prints the summary block, closes `R` and calls `exit(1)`, the first nonzero of (0, 1, 0).
14. **Next run.** It reuses `K`, `M` (same content) and the images in `P`; loading takes about 0.1 s.

---

## D30 Process model

**Decision.** DispatchCheckup (DC) activates in the process that calls `dispatch_doctor` (the owner) and never relaunches the suite. Activation derives and prepends `M`, builds the instrumented images, exports the redirect, sets `DISPATCH_CHECKUP=checked`, registers its `atexit` hooks and returns. The suite's own `using` then loads the instrumented target. DispatchDoctor (DD) is used only as a runtime library inside DC's generated wrappers (O4). One finalizer hook validates, writes the report, runs the guard child and sets the final status. A second hook, the D50 reaper, only kills a guard child still alive after a signal (Resolved (default): exactly these two atexit hooks).

**Requirements**

- **Classification.** It follows S4's state machine (steps 1–8). Nothing before ACTIVATE mutates process state.
- **ACTIVATE mechanics**, in this order (S4's ACTIVATE list is the observable summary):
  1. Snapshot (D18).
  2. Store: key check, GC and overlay writes (D17+D47, D13).
  3. Derive and write `M` (D24, D45).
  4. Create `R` and `R/state.toml`, write the report placeholder, and set `ENV["DISPATCH_CHECKUP_RUN"]`.
  5. Pin the active project, `pushfirst!(LOAD_PATH, M)`, run the up-front build with `DEPOT_PATH=[P; U]`, and restore `DEPOT_PATH=[U; P]` in `finally` (D04, D17).
  6. Install the include-leak callback (D02/D32) and the identity callback (D16).
  7. Export the redirect (D12).
  8. Call `Base.exit_on_sigint(true)`. Register the reaper hook, then the finalizer hook. Atexit runs LIFO, so the finalizer runs first and the reaper last. These are DC's only two atexit hooks (Resolved (default)): the finalizer does validation, reporting, guards and the exit status; the reaper only kills a guard child still alive after a signal, and does no validation, reporting or guard work.
  9. Set `ENV["DISPATCH_CHECKUP"]="checked"` last, print the banner, and return `nothing`.
- **Rollback.** An exception in steps 2–9 restores `LOAD_PATH`, `DEPOT_PATH`, `Base.ACTIVE_PROJECT`, `ENV` and the callbacks from the snapshot, unregisters the hooks, writes `status="failed"`/`failures=["setup"]` to the placeholder if it exists, and rethrows. Files under `R0` may remain.
- **Finalizer.** One function with an untyped argument: a method typed `(c::Int)` fails `hasmethod(f,(Cint,))`, gets called with no argument, and exits 0. Its whole body runs inside `try`/`catch`, and an internal error prints, writes `failures=["setup"]` if it can, and exits 1 when the code was 0. The steps:
  1. If `code >= 128`, or `current_exceptions()` holds an `InterruptException`: write `status="interrupted"`, close `R` and return without calling `exit`, so 130 or 143 propagates.
  2. Run the end-of-run self-test and canary (D16).
  3. Append the owner's `clean_exit`, merge `R/proc/*`, and list processes that are still running or unfinished (D12). DC kills no member process. Conflict 11's "stop known workers" step is met by the frameworks themselves. Distributed and Malt register their worker-stopping `atexit` hooks after activation (pre-existing workers are refused, D12), so under LIFO order those hooks run before this finalizer. ReTestItems stops its workers before `runtests` returns.
  4. Run the method-table audit (D44).
  5. Validate: identity, load mode, build failures, config digest, include leaks, `unstable=` matching, `require_all` (only blind spots not listed in `unstable=` count; DD limitations are reported with locations and counts, never counted, S4 D11), the record-mode instabilities, and target-never-loaded (#60).
  6. Write the report with guards pending, `flush(stdout)`, `flush(stderr)`, and `GC.gc(true)`.
  7. Run the guard phase (D18/D50), unless `original=` is empty or the target never loaded.
  8. Write the final report atomically, print the summary block (S4), and mark `R` closed.
  9. Compute `final` as the first nonzero of (code, validation, guards). Call `exit(final)` only when `final != code`.
- **Import has no side effects.** `import DispatchCheckup` alone must have no observable side effect (O1).
- **Marker text.** DC's own entry file must not contain the literal text `__precompile__(false)`: Base's parallel precompile skips any package whose entry text matches it (precompilation.jl:1222).
- **Documented residuals.**
  - A hard crash, an OOM kill, or a libc `exit`/`_exit` skips the finalizer. A libc `exit(0)` is a false pass that only the `incomplete` placeholder exposes. A C-level `__cxa_atexit` handler corrupted the heap, so none is used.
  - Peak memory is the owner plus the guard child.
  - A suite hook registered after activation that calls `exit(n)` changes the code the finalizer sees.

**Rationale.**

- The relaunch was the root of the largest finding cluster: #0 (critical), #9, #31, #34, #35, #36, #44, #59, #76 and #119.
- In-process activation was prototyped on 1.13.2 under the `[extras]`, `test/Project.toml` and `[workspace]` layouts. The image was built in a worker and reused across sandboxes, the guard child saw the original code, coverage worked, `@main` ran before the hook, and SIGTERM and SIGINT reached the hook as `n=128` (`$AUDIT/D30-process-model-k7w2`).
- Atexit hooks run before mktempdir cleanup (base/file.jl:747-753) and can spawn and wait on a child (`$AUDIT/canon-x9q4`).
- `Base._atexit` catches hook exceptions and keeps the exit code (initdefs.jl:484-494). Hence the fail-closed finalizer (`$AUDIT/D15-entry-discovery-r8t5`).

**Tests**

- Run `Pkg.test` under each of the three layouts, plus a direct `julia --project=test test/runtests.jl`. The suite fails, then validation fails, then guards fail; in each case the exit code is the first nonzero.
- A suite that calls `exit(0)` explicitly is still validated.
- A finalizer that throws exits 1.
- `@main` runs before validation.
- SIGINT and SIGTERM, sent to the julia pid directly, give `interrupted`, no guard child, and rc 130 or 143.
- An injected failure at each ACTIVATE step leaves `ENV`, `LOAD_PATH`, `DEPOT_PATH`, `ACTIVE_PROJECT` and the hook count unchanged.

---

## D24 Environment derivation

**Decision.** DispatchCheckup (DC) derives a minimal environment `M` with Base's own resolvers, writes it once into `K/env/<hash>/`, pins the active project, and prepends `M` to `LOAD_PATH`. `M` changes how the target UUID resolves and nothing else. DispatchDoctor (DD) and DC enter `M` only as dependencies of the target record.

**Requirements**

- **Pin first.** If `Base.ACTIVE_PROJECT[] === nothing`, call `Base.set_active_project(Base.active_project())` before the prepend, and record that pinning happened (D12 uses it). `M` is never the active project.
- **`M/Project.toml`.** The target goes under `[extras]` only, never `[deps]`, plus the preference-alias extras below. Without `[extras]` the preference is ignored; under `[deps]` the target name would leak into name lookup.
- **`M/Manifest.toml`: the target record**
  - `path` is `O`.
  - `entryfile` is `relpath(located entry, root)` when it is not `src/<Name>.jl` (#30).
  - It copies the target's `version`, `extensions` and `weakdeps` (as name=uuid tables).
  - `deps` holds the target's deps as name=uuid, plus DispatchDoctor and DispatchCheckup.
  - It has no `git-tree-sha1` or `repo-*` keys.
- **`M/Manifest.toml`: the closure**, the transitive deps of the target record:
  - Each record is copied from the environment where `Base.locate_package_env(pkg, stopenv)` locates it in the owner before the prepend. If production cannot locate it, activation fails with the package name and stopenv.
  - DD, DC and their closure are resolved from DC (`identify_package_env(DC_id, name)`), not from `Main`.
  - `deps` and `weakdeps` are rewritten as name=uuid tables; vector-form `weakdeps` throws `KeyError` in `_insert_extension_triggers`.
  - `git-tree-sha1` records stay hashes. Path records are absolutised. Stdlib records carry no `path`.
  - Records for implicit (package-directory) environments, and for a project that is itself the package, are built from its `Project.toml`: path, entryfile, deps, weakdeps and extensions.
  - Workspace records are found through `Base.project_file_manifest_path` and absolutised.
  - Weakdep records are not added; extension loading ignores stopenv.
- **Loaded closure packages.** Every closure package already loaded at activation must have a `pkgorigins` path equal to its located path. Otherwise activation fails.
- **`M/LocalPreferences.toml`.**
  - For every closure UUID with preferences, write the merged view `Base.get_preferences(uuid)` returned *before* the prepend, keyed by name or by a `DispatchCheckupPreference_<uuid>` alias listed in `[extras]`, as 0.1's `_temporary_preferences!` does.
  - Add the D45 table for the target.
  - DC writes no DD keys and never `__clear__`. This supersedes conflict 17: O4's template, not DD's macro, emits every check. This is the 0.2.0 rule. On the branch, S5's P1 transitional rules keep 0.1's forced DD keys until P2.1.
- **Content address.**
  - `<hash>` is `crc32c` over the canonical TOML of the three files.
  - Write into a temporary sibling, then rename. On reuse, verify the bytes. If they differ (CondaPkg, or `set_preferences!(…; active_project_only=false)` wrote into `M`), use `K/env/<hash>-<rand>` for this run and note it.
  - Never rewrite `M` in place.
- **Never** read `pwd()`, and never copy the active manifest wholesale.
- **Compat module.** Every Base internal goes through it: `identify_package_env`, `locate_package_env`, `env_project_file`, `project_file_manifest_path`, `base_project`, `entry_point_and_project_file`, `set_active_project` and `ACTIVE_PROJECT`.
- **Documented divergences**
  - With a pure implicit load path, or after `Pkg.activate()` with no argument, `M` can become the active project. The finalizer reports `active_project() == M`.
  - A PythonCall target gets a conda environment rooted at `M`. Because `M` is content-stable, it is built once per content.
  - Preference writes with `active_project_only=false` land in `M`.
  - Members that inherit `M` see the closure's versions for other projects (D12).

**Rationale.**

- Base resolves a UUID in the first environment that knows it, and a package's deps in the environment that provided it.
- A prototype loaded every non-target package exactly as production did in nine layouts: devdir, stacked envs, stopenv, a target present in two envs, a workspace member, a custom entryfile plus extension, Compat's vector weakdeps, a `Pkg.test` grandchild, and Pkg API calls (`$AUDIT/D24-environment-derivation-r8k3`).
- An unpinned prepend made `M` the active project under `Pkg.test`, because `active_project()` falls back to the first explicit entry (initdefs.jl:345-352).
- `[extras]`-only keeps `identify_package` from an empty environment returning `nothing`, as in production (`$AUDIT/D30-process-model-k7w2`).
- Prepending drops the workspace-root preferences of every package unless the merged view is copied (`$AUDIT/D45-config-transport-k8v3`).

**Tests**

- The nine prototype scenarios as fixtures.
- `Pkg.activate(@__DIR__)` after activation still loads the overlay (#113).
- Stopenv refusal matches production's failure (#98).
- `M` reuse is byte-stable across runs.
- A mutated `M` is not reused.
- Workspace-root preferences survive.
- `identify_package` from an empty environment returns `nothing`.

---

## D13 Overlay identity

**Decision.** The DispatchCheckup (DC) overlay `O` holds exactly three kinds of file:

- a byte-identical copy of the target's `Project.toml` or `JuliaProject.toml`;
- the entry shim, at the relative path of the located entry;
- one shim per extension, at the original relative path.

Each shim rewrites `Base.pkgorigins` so `pathof`/`pkgdir` report the checkout, then has DC include the original sources in place through the mapper. There is no tree copy, snapshot, mirror, symlink, junction, fingerprint or `share_assets`. DispatchDoctor (DD) and DC appear only in `M`'s target record.

**Requirements**

- **Shim text.** It must be a deterministic function of the target `PkgId`, the extension `PkgId` (extension shims only), the realpath of the original entry, DC's layout version, and whether the original contains the literal `__precompile__(false)`. It contains nothing per run and no config (D45). The exact form:

  ```julia
  # DispatchCheckup overlay shim, layout 1. Generated; do not edit.
  Base.require(Base.PkgId(Base.UUID("ca055ede-32eb-4961-937e-82d9c5ec6430"), "DispatchCheckup"))
  Base.loaded_modules[Base.PkgId(Base.UUID("ca055ede-32eb-4961-937e-82d9c5ec6430"), "DispatchCheckup")]._load_original(
      @__MODULE__, Base.PkgId(Base.UUID("<uuid>"), "<Name or ExtName>"), "<realpath of original entry>")
  ```

  - An extension shim passes the target's PkgId as a fourth argument, `Base.PkgId(Base.UUID("<target uuid>"), "<Name>")`. The extension's build needs it to read the target's D45 table and to decide ownership (`uuid5`), and `uuid5` cannot be inverted. The signature is `_load_original(toplevel::Module, id::Base.PkgId, original::String, target::Base.PkgId = id)`.
  - When the original contains the literal `__precompile__(false)`, it is mirrored as the shim's first line.
  - The shim defines no closure or binding, because a closure in `__toplevel__` fails precompilation.
  - The shim never uses `invokelatest` (O1). The `require` and the call are two top-level statements, so the call runs in the world in which DC is loaded, even when this `require` loaded it. A two-statement shim of this shape precompiled and was reused on Julia 1.13.2 (spec-review probe; P1.0(b) re-verifies it).
- **Extension shims.** The original extension entry is found the way `Base.find_ext_path` does: `ext/X/X.jl`, then `ext/X.jl` (#58). Extension PkgIds are `uuid5(target uuid, X)` (#23).
- **`DC._load_original`** (build worker or source-load fallback):
  1. In a build worker, run the D46 gate. In the source-load fallback (not generating output, so `P` is last on `DEPOT_PATH`), require only that `DISPATCH_CHECKUP_RUN` names a live run.
  2. Read `CompileConfig` from `target`'s D45 table, and derive `root` (seam, above).
  3. Run the static DD self-test (S3.2 (a); D16).
  4. Set `Base.pkgorigins[id].path` to the original entry, under `Base.require_lock`.
  5. Install the scoped DD-warning filter and the build include observer.
  6. Call `Base.include(mapper, toplevel, original)`.
  7. After the include returns, throw the collected bypass and rewrite failures once (D46).
- **Identity in every phase.** At precompile time the shim prologue provides it; at load, in every process, the hook `__init__` (D46). Extensions follow the same rule.
- **Overlay `Project.toml`.** It never gains `[deps]` or `[compat]` (#104).
- **Writes.** Temporary file, then rename, and only when the bytes differ. That makes them idempotent across concurrent runs of one checkout.
- **Hook insertion.** If the walker cannot insert the hook (a docstring-wrapped module, an entry that includes the file defining the module, or the 1.14 `Expr(:module)` shape), that is a setup error with the location. `baremodule` roots are supported: the hook is inserted using GlobalRefs only (S6a requirement 4).
- **Documented**
  - `Base.locate_package`, `find_package` and `CodeTracking.basepath` return the shim.
  - One hidden name, `Symbol("#DispatchCheckup")`, appears in `names(M; all=true)`.
  - Writes through `pkgdir` reach the checkout, as in production, and source edits during a run are visible.
  - Revise is unsupported (D14).
- **Fallback.** A hardlink-or-copy tree is a written contingency for a Julia that stops reading `PkgOrigin.path` in `pathof`. It is not built.

**Rationale.**

- Identity everywhere was verified on 1.13.2 and on 1.14.0-DEV.3787:
  - the shim prologue gives `pkgdir` = checkout at precompile time;
  - a first-statement submodule's `__init__` runs before every other `__init__`;
  - images are reused, and invalidated by edits to the original sources;
  - an unmodified overlay `Project.toml` loads;
  - ReTestItems' `runtests(M; nworkers=0)` stays in-process;
  - `--project=$(pkgdir(M))` subprocesses work.

  Evidence: `$AUDIT/D13-overlay-identity-r8m4` and `$AUDIT/D46-image-runtime-hooks-12387`.
- The seed's mirror reintroduced #1: `cp` followed by a write changed the checkout.
- Base reads `PkgOrigin.path` only in `pathof`, `pkgdir`, `pkgversion` and `extension_parent_name`; staleness checks and extension triggers use `locate_package`.

**Tests**

- `pathof`, `pkgdir`, `pkgversion`, `source_path`, `@__FILE__` and `@__DIR__`: at precompile time, in the root `__init__` and in a submodule `__init__`, at run time, for both extension layouts, and under the source-load fallback.
- Copying a `pkgdir` asset and writing to the copy leaves the checkout unchanged.
- A `--project=$(pkgdir(M))` subprocess works.
- ReTestItems stays in-process.
- Editing an original source triggers a rebuild.
- `cmp` of the overlay `Project.toml` against the original.
- A shim with the `__precompile__(false)` mirror.
- Each hook-insertion failure shape gives its setup error.

---

## D04 Load mode

**Decision.** The instrumented target, its extensions and its dependents load from persistent images that DispatchCheckup (DC) builds eagerly at activation into `P`, with the build output captured. Base decides every fallback. A load-mode assertion makes silent fallbacks fail closed. DispatchDoctor (DD) checks are off while images are generated, so module-body code runs unchecked, as with native DD.

**Requirements**

- **When to build.** The up-front build runs iff `JLOptions().use_compiled_modules == 1` (yes):
  - `0` (no): the target source-loads in-process through the same shim and hook;
  - `2` (existing): Base loads an existing image from `P`, or source-loads;
  - `3` (strict): Base raises its own error if no image exists. Resolved (default): this is accepted and documented, not worked around. A first checked run in this mode errors until a run under the default `yes` has populated `P`.

  DC never forces a flag. `--pkgimages=no` still uses `.ji` images.
- **Build set.** `Base.Precompilation.precompilepkgs` over the pinned active environment, with `io=IOBuffer()` and `DEPOT_PATH=[P; U]` inside `try`/`finally`. The set covers:
  - the target, located through `M`;
  - every dependent;
  - every extension present;
  - plus the explicit PkgIds of every target extension whose triggers are all resolvable at activation, because `precompilepkgs([target])` keeps an extension only if its triggers are in the kept closure.

  This settles S1 open point 2 in favour of D17's set, and keeps conflict 12's capture. Fallback through the Compat module: `Base.compilecache` per package in dependency order.
- **Precondition.** DC and DD are already loaded from images in the owner, so the target record's DC and DD deps never need building.
- **Output**
  - Build workers drop only DD's "no compatible functions" records, through a scoped logger (#75/#120).
  - The captured output is filtered and printed to `stderr` before the banner.
  - DC prints nothing between the banner and the end of the suite.
- **Build failure.** A `PkgPrecompileError` is a setup error at activation. The message quotes the captured output and the `R/build-failures` files (D46), and states whether the original precompiles, using `Base.isprecompiled(target)` taken at the snapshot.
- **Post-build assertion.** The target and each built extension satisfy `isprecompiled`, with the cache under `P`; the same holds for every dependent that was built.
- **Per-image status** recorded for the report: `reused`, `rebuilt`, `lazy` (a dependent built after activation, with its depot), or `source-loaded` (with the reason).
- **Load-mode assertion** (validation). Every loaded image of the target and its extensions came from `P`, unless:
  - (a) `use_compiled_modules` is 0, or is 2 with no image;
  - (b) the original contains the literal `__precompile__(false)`.

  The target and its extensions are never `lazy` (D46 gate).

  Any other source load is a setup error. One example: Base's serial `compilecache` failure path, which warns and source-loads (loading.jl:2835-2846).
- **Invalidation hygiene**
  - DC adds `include_dependency` only with `track_content=true`. With mtime tracking, every fresh CI checkout would invalidate.
  - DC code that is baked into images must not derive paths from `@__DIR__` (lesson of #39); use `pkgdir`.
- **Documented**
  - Generator-time detections depend on which specializations are in the image, as with native DD.
  - Load-time and module-body instabilities are not detected unless tests call that code (conflict 14).
  - A cold cache rebuilds every dependent once, so the CI recipe must restore the cache (S4 D40).

**Rationale.**

- Under in-process activation, source loading is only Base's fallback. A per-run image would rebuild every dependent on every run.
- The persistent image was reused: 4.06 s, then 0.14 s.
  - A `touch` kept the image (Base compares size and crc32c).
  - A content edit, a config change or a helper upgrade rebuilt it.
  - An ordinary run in between saw 0 rejections.
  - An implicit build leaked worker output into `@test_nowarn`.

  Evidence: `$AUDIT/D04-load-mode-x7q2`.
- The cache slug ignores the entry path (loading.jl:3334-3352), so instrumented images must never be written where production looks first.

**Tests**

- Cross-run reuse.
- An ordinary run in between is untouched (zero `Rejecting` lines under `JULIA_DEBUG=loading`).
- Invalidation on a source edit, a config change and a DC upgrade.
- `--compiled-modules=no`, `existing` and `strict`; `--pkgimages=no`.
- `__precompile__(false)`.
- A simulated walker failure in a worker gives a setup error that names the cause.
- A forced serial-path fallback fails the load-mode assertion.
- `@test_nowarn using MyPackage` passes.
- An extension whose trigger is only a test dependency is built up front.

---

## D17+D47 Depot, caches and persistent state

**Decision.** All DispatchCheckup (DC) persistent state lives under `R0`, one key directory per checkout. `P` is first on `DEPOT_PATH` only during the up-front build. It is last at runtime and last in the exported `JULIA_DEPOT_PATH`, so every runtime depot write lands in the user depot exactly as in production. No entry of the user depot is mirrored. DispatchDoctor (DD) is unaffected.

**Layout (layout version 1)**

```
R0 = $DISPATCH_CHECKUP_DEPOT  or  <DEPOT_PATH[1]>/compiled/v1.13/.dispatchcheckup     (realpath once, #52)
R0/v1/<Name>-<uuid8>-<crc32c8(realpath root)>/     = K
    key.toml       name, uuid, root (realpath), layout = 1
    stamp.toml     last_used = <Unix seconds from time(), written inside the file; DC has no Dates dependency (O14)>
    overlay/       = O   (sibling of depot/, never inside it; resolved default, see the technical point below)
    depot/         = P   (compiled/v1.13/<Pkg>/*.ji|.so; precompile-time writes of closure packages)
    env/<hash>/    = M
    report.toml    default report (S4 D22)
```

**Requirements**

- **Location**
  - `v1.13` comes from `VERSION`.
  - If `DEPOT_PATH[1]` is not writable and no override is set, `R0` becomes a temporary directory and a one-line warning says nothing will persist.
  - `DISPATCH_CHECKUP_DEPOT` must be absolute. It is machine-level: tests never read it (S4 D31).
  - An empty value counts as unset. A relative value is a FRESH-precondition error (S4 step 8). An override that cannot be created or written is an ACTIVATE step 2 error, with rollback. Neither case falls back to a temporary directory.
- **Key identity.** `key.toml` must match (name, uuid, root, layout). A mismatch (a crc collision) makes this run use `K-<rand>` and report it. A missing `K` means a rebuild, never an error.
- **Depot order**
  - Build: `DEPOT_PATH = [P; U]`.
  - Runtime: `[U; P]`.
  - The swap is exception-safe and happens before any test code runs.
- **Runtime writes.** Scratch, lazy artifacts, logs, conda environments, DataDeps and Pkg operations go to `U`. Writes that closure packages make while precompiling (a top-level `get_scratch!`, a workload that fetches an artifact) land in `P`; this is documented.
- **Lazy builds.** Resolved (default). Only images of dependents and third-party extensions (kind W) can be built after activation, and these are allowed. They are written to `DEPOT_PATH[1]`, that is `U`. Causes include a test-created environment or a member with different flags. The target and its extensions are never built lazily: the D46 gate refuses, fail loud.
  - A lazy dependent's slug carries the D45 preference, so it lands under a distinct cache slug and never overwrites a production file in place. It only adds files that count toward Base's 10-file eviction.
  - The finalizer lists every target-closure package whose cache is outside `P` as a `lazy` warning (D04).
  - The zero-files contract (S5 C-12) therefore covers the target and its extensions only: zero files in `U/compiled` for them. Dependents add files there only through a reported `lazy` build.
- **Concurrency**
  - Base's `compilecache` pidfiles protect cache files; three concurrent runs serialised and passed.
  - DC's own writes are idempotent (temporary file, then rename, only on change) or write-once (`env/`), so DC takes no lock. That respects O14's dependency list (no FileWatching).
  - GC deletes by renaming to `R0/.trash-<rand>` first.
- **GC at activation.** Refresh the own stamp first. Then delete keys of other layout versions, keys whose recorded root is gone, and keys whose stamp is older than 30 days. Inside `P`, rely on Base's per-package 10-file eviction.
- **Reset.** `K` is printed in the banner and the report. The documented resets are `rm -rf K` and `rm -rf R0`; `rm -rf ~/.julia/compiled` also resets.
- **CI.** julia-actions/cache saves `compiled/` of the first depot by default, so `R0` persists. Document the 10 GB per-repository limit and `DISPATCH_CHECKUP_DEPOT` as the opt-out.

**Rationale.**

- Base searches every depot for caches (`find_all_in_cache_path`, loading.jl:1239) and writes only to `DEPOT_PATH[1]` (3329-3336).
- With a build-only private depot that was then appended, every instrumented image loaded from it, zero files were written to the user depot, the second build took 0.11 s, production was unaffected, and a process with `P` but without `M` stayed production.
- The mirror alternative produced alias `pathof` strings, a symlink cycle and an open-ended entry list (`$AUDIT/challenge-D17-depot-layout-r8k3/exp`).
- Pkg 1.13's `gc` never references `compiled/`, and a dot folder never matches a cache lookup.
- UUID-only keys rebuilt on every switch between checkouts, and raced when concurrent (`$AUDIT/D47-persistent-state-cbe97c0c`; conflict 0).

**TECHNICAL POINT (Resolved (default): sibling layout, no mirrors): `@depot` relocation, and whether `dev/` and `packages/` must be mirrored**

- **Mechanism.** At build, Base rewrites each include path against the first depot that prefixes it (`replace_depot_path`, loading.jl:3562). At load, it resolves each `@depot` path against the first depot where the file exists (`resolve_depot`, 3589). Paths that resolve to different depots are not restored, and the cache is rejected (3688-3725). This matters when the target lives inside a depot (`~/.julia/dev`, `~/.julia/packages`), because the image's include list then mixes the shim with the original files.
- **Disagreement**
  - The D47 challenger requires `O` inside `P` plus mirrors of `dev/` and `packages/`. Its experiment kept `P` first at runtime: `exp1.sh` sets `JULIA_DEPOT_PATH=$P:$U` on every run.
  - The D17 challenger requires no mirroring, and the owner adopted D17's order (`P` last at runtime).
- **Preliminary probe** (by this section's writer, on 1.13.2, in the owner order: build `[P;U]`, runtime `[U;P]`; to be archived with the P1 prototype). A one-file `Foo` was loaded twice after the build, with `JULIA_DEBUG=loading`:

  | target location | `O` inside `P` (D47) | `O` inside `P` + `dev`/`packages` mirrors | `O` sibling of `P` in `K` | `R0` outside `U` |
  |---|---|---|---|---|
  | external checkout | reused | — | reused | reused |
  | `U/dev/Foo` | rejected every run; rebuilt into `U/compiled` | rejected; rebuilt into `U/compiled` | reused, 0 rejections | reused |
  | `U/packages/Foo/<slug>` | — | rejected; rebuilt into `U/compiled` | reused, 0 rejections | — |

  Reading: under the owner's order, D47's layout fails and the mirrors do not help. What matters is that the shim and the original files relocate against the same depot (`U`), so `O` must not sit inside `P`. This spec therefore adopts the sibling layout above with no mirrors as the **resolved default**; the P1 prototype below is its acceptance gate.
- **P1 prototype that confirms it.** The matrix has four axes:
  - target in {external checkout, `U/dev`, `U/packages`, a secondary user depot};
  - layout in {sibling, inside-plus-mirror, `R0` outside `U` via the override};
  - image in {root, extension, dependent};
  - process in {`Pkg.test` sandbox, direct script, member with the exported depot order}.

  Add a julia-actions/cache restore onto a fresh checkout (new mtimes) and macOS `/private/var` paths. Acceptance on runs 2 and 3: zero `Rejecting cache file` lines, zero new files in `U/compiled` for the target and its extensions, and every image `reused`, dependents included (none `lazy`; the fixtures have no lazy-build cause). Commit the layout only when every cell passes. A failing cell becomes a documented rebuild case, visible through the per-image status. Mirrors return only if no mirror-free layout passes, and then D25's Windows junction questions return with them.

**Tests**

- Zero writes to `U/compiled` for the closure, the target and its extensions; dependents add files there only through a reported `lazy` build.
- Scratch writes land in `U`.
- Three concurrent runs of one checkout, and two checkouts alternating, all reuse their images.
- `Pkg.gc()` leaves `R0` in place.
- A `key.toml` collision.
- GC of a key whose root is gone.
- An unwritable `DEPOT_PATH[1]` falls back.
- A lazy-build warning fixture.

---

## D45 Config transport

**Decision.** DispatchCheckup (DC) puts the options that change generated code in one canonical preference table, `dispatch_checkup`, for the target UUID in `M/LocalPreferences.toml`. Base's prefs-hash staleness check then keys, invalidates and keeps image variants. Runtime-only options travel in `R/state.toml`. DispatchDoctor (DD) preference keys are neither written nor forced.

**Requirements**

- **Compile-time table** (always complete and canonical; array order changes the key, table key order does not):

  ```toml
  [MyPackage.dispatch_checkup]
  schema = 1                    # transport schema
  rules = 1                     # matching-rules / template / macro-table version (S3.1 R3)
  unstable = ["..."]            # canonical selector spellings, sorted, deduplicated (S4 D10)
  union_limit = 1
  codegen_level = "debug"       # plus any template parameter S3 exposes as an option
  ```

- **Runtime-only** (`R/state.toml`; never in an image):
  - `mode`, `report`, `require_all`, `original`;
  - run id, owner pid, target, `K`, `M`, `P`;
  - the snapshot pieces that members need (below).
- **`R/state.toml` keys.** It is written once at ACTIVATE step 4 (temporary file, then rename). Afterwards only `status` changes.
  - Keys: `schema = 1`, `run_id`, `owner_pid`, `host`, `status` (`"open"` or `"closed"`), `[target]` (`name`, `uuid`), `key_dir` (`K`), `env` (`M`), `compile_depot` (`P`) and `digest`.
  - Tables: `[compile]` holds the D45 table verbatim, for JOIN's comparison; `[runtime]` holds the `RuntimeConfig` fields; `[snapshot]` holds the activating file, the path base and the project D24 pinned (or `""`). The finalizer runs in the owner and reads the full D18 snapshot from memory, so no `ENV` value is ever written under `R`.
  - Readers: the D46 gate, the D16 role-marker check and members. A run is *live* when the file exists, `status == "open"`, and `owner_pid` is alive on `host` (checked through the Compat module).
- **Build-time reading.** The config is read only through `Preferences.load_preference(target_uuid, "dispatch_checkup")`, which is public and records the compile-time preference. Preferences therefore stays in `[deps]` (O14); it is already in DD's closure.
  - A missing table, or a schema or rules mismatch, is a build error.
  - Extension builds read the target's table (verified to key extensions).
- **Dependents are keyed too.** The hook `__init__` calls `Preferences.load_preference(target_uuid, "dispatch_checkup")` when `jl_generating_output() == 1`, so dependents and third-party extensions keep one image per config.
- **Build-time purity.** Code that runs while an image is generated must not read `ENV`, `R`, `Base.active_project()`, `pwd()` or `ARGS` for anything that affects generated code. There is one carve-out: the D46 gate and its failure files, which never change generated code. S4 D31 states the same carve-out.
- **Digest.** The config digest is `crc32c` of the canonical table, that is, of the bytes `TOML.print(io, table; sorted = true)` writes. The same canonical form is used for `M`'s content hash (D24). It is baked into each hook's `IMAGE`, and validation compares it with the run's digest; a mismatch fails closed.
- **Descendant activation** (conflict 18). A difference in a compile-time option is an error that names both values. Runtime-only differences are noted and ignored (S4 JOIN).
- **Documented**
  - One image per distinct config, per package.
  - Base keeps at most 10 per package, evicting the oldest write mtime first.
  - A user `dispatch_doctor_*` preference for the target is copied unchanged via the D24 merged view; S3 decides how the template honours it.

**Rationale.**

- Changing the value rebuilt the image, reverting it reused the first (0.01-0.05 s), and concurrent configs coexisted.
- A DC upgrade invalidates through build ids.
- Without the hook record, a dependent rebuilt on every switch (0.61 s against 0.046 s).
- The worker inherits `ENV` and sees `active_project() == M`, so the "worker sees nothing" premise was false.
- A 5000-entry list costs 115 KB and a 0.048 s load.

Evidence: `$AUDIT/D45-config-transport-k8v3` and `$AUDIT/critic-completeness-q7r3`.

**Tests**

- A config change rebuilds; reverting reuses the earlier image.
- The same config under two different `R` values reuses the image.
- A dependent is not rebuilt after a config round trip.
- A reordered `unstable=` reuses the image.
- A missing table fails the build.
- A digest mismatch fails validation.

---

## D46 Image runtime hooks and process kinds

**Decision.** The walker inserts one private submodule, `var"#DispatchCheckup"`, as the first statement of the target root module and of each extension root module. DispatchCheckup (DC) code runs in the build worker through the shim, and in every process that loads an image through the hook's `__init__`. Behaviour depends on the process kind. DispatchDoctor (DD) runtime helpers are reached only through the template and the self-test.

**Hook content** (generated). It references DC through GlobalRefs and adds no other binding to the user module:

```julia
module var"#DispatchCheckup"
    const SINK   = <DC.RecordSink>()           # evaluation-time records of this image (D05)
    const CONFIG = <DC.CompileConfig literal>  # the decoded D45 table this image was built with
    const IMAGE  = (id = <PkgId>, target = <target PkgId>, original = "<entry>", root = "<checkout root>",
                    digest = <UInt32>, layout = 1)
    record!(r, f)  = <DC._push_record!>(SINK, r, f)   # the D05 push that S3.1 R6 emits
    module_end!(m) = <DC._module_end!>(SINK, m)       # the S3.4 end-of-module record
    # template-generated canaries (S3): canary_stable, canary_unstable; they report to a private
    # counter, never to the run's records, and never throw
    __init__() = <DC._hook_init>(@__MODULE__, SINK, IMAGE)
end
```

**Process kinds**

| kind | recognised by | DC runs |
|---|---|---|
| B: build worker for the target or an extension | `jl_generating_output()==1`, inside `_load_original` | gate; config; self-test; `pkgorigins`; walk; records into `SINK`; throw collected failures once |
| W: worker building a dependent or a third-party extension | `jl_generating_output()==1`, hook `__init__` | `pkgorigins` rewrite and the D45 preference record **only**: no canary, no registration, no file, no marker check |
| O: owner | DC's in-memory activation state | full `__init__`, below; also merge, validation, report and guards at exit |
| M: member | `DISPATCH_CHECKUP=="checked"`, a live `R`, the same target | full `__init__`; a per-process record file |
| X: stale | not generating, and `R` missing, closed or for another target | `InitError` naming the target and `M`; no fallback |
| G: guard child | plain Base runner | DC is not loaded; the bootstrap runs the inverse identity check (D18) |

**Requirements**

- **Gate** (kind B). The build is refused unless `DISPATCH_CHECKUP_RUN` names a live run and the run's `P` is `DEPOT_PATH[1]` (decisions.json D46 (2)). An instrumented target or extension image is therefore never written to `U`, which keeps S1 §2 and D51 history independence.
  - A kind B build after activation (runtime order `[U; P]`) is refused the same way. The message names the likely cause: an extension whose trigger was not resolvable at activation, a test-created environment, or a member started with different flags.
  - Resolved (default): the refusal fails loud and is a documented divergence from production. For example, a late-triggered extension or a test-created environment cannot load the target in a checked run. Lazy builds of dependents and third-party extensions (kind W) after activation stay allowed and are reported as `lazy` (D17+D47).
  - Failures are collected and thrown once, after the entry include returns, outside any user `try` (#56 patterns). The exception is ordinary, never a `PrecompilableError` or exit 125.
  - Each failure (package, message, location) is also written to `R/build-failures/<pkg>-<pid>-<rand>.toml`, because the `PkgPrecompileError` the owner catches carries no cause.
- **Full `__init__`** (kinds O and M):
  1. Rewrite `Base.pkgorigins[IMAGE.id].path = IMAGE.original` under `Base.require_lock`, then assert `pathof == IMAGE.original` (a Compat self-check).
  2. Register `(IMAGE.id, IMAGE.digest)` and `SINK` *by reference* with DC's per-process collector. The hand-off comes from inside the hook, because DC-side access to `SINK` after the include triggers 1.13's world-age binding warning.
  3. Install the process include observer once per process. It is scoped to modules the target owns, not to source paths (#26). It covers Requires-style and lazy runtime includes and the source-load fallback, under conflict 21's rule. In a member, the hook also installs, once per process, the D16 identity callback and the D02/D32 include-leak callback for the `original=` files listed in `R/state.toml` (the owner installed both at ACTIVATE step 6).
  4. A member opens `R/proc/<host>-<pid>-<rand>.toml`, writes `loaded`, starts its flusher and registers its `clean_exit` atexit hook (D12).
  5. Run the image canary iff `checking_enabled()`. A skipped canary is not a failure; the owner's end-of-run canary is authoritative (D16). A member also runs the static DD self-test once per process (D16).
- **Infer-disabled roots.** When the root module has `jl_get_module_infer == 0`, the hook skips the canaries and self-test and registers the image as inference-disabled (S6a requirement 4).
- **Records.** They always go to the `SINK` of the image being walked; an extension cannot write into the root's closed image (conflict 3). Each record carries its defining module. The collector reads `SINK`s at flush time, so records from code evaluated at run time are kept.
- **Kind X.** The message names the target, `M` and the likely cause: an exported environment outliving its run, or a scrubbed subprocess.
- **Kind W.** It must never run a canary: DD disables checks while generating output, so a canary there would fail every dependent build.
- **Compat module.** The Base internals used here (`PkgOrigin.path`, `require_lock`, `include_callbacks`, `package_callbacks`, `jl_generating_output`, `jl_get_module_infer`, submodule-first init order) each get a contract test.

**Rationale.**

- The hook `__init__` ran before every other `__init__`: in an included submodule, the root, an early `baremodule` submodule and an extension.
- `isprecompiled` stayed true after the rewrite, and images were reused in 0.0 s with their records intact.
- Workers of dependents and extensions ran the hook with `gen=1` and the marker inherited.
- A worker error reached the owner only as a bare `PkgPrecompileError`.
- A missing marker gave an `InitError`, with no fallback.

Evidence: `$AUDIT/D46-image-runtime-hooks-12387`.

**Tests**

- Init order in all four shapes.
- A kind W build with the canary absent.
- A kind B build with `P` not first on `DEPOT_PATH` (a late extension trigger) is refused, and nothing is written under `U/compiled` for the target.
- A worker failure surfaces its cause through `R/build-failures`.
- A swallowed include error still fails the build.
- A kind X `InitError`.
- A runtime include into an owned module is observed.
- No world-age warnings on stderr.
- A `baremodule` root.
- An infer-disabled root (the S6a fixture).

---

## D12 Descendant processes

**Decision.** DispatchCheckup (DC) exports the redirect to every descendant Julia process. Every process that loads the image records write-through into its own file under `R`; the owner merges them at exit. Distributed workers that predate activation are refused. DispatchDoctor (DD) checks run identically in members.

**Requirements**

- **Export** (ACTIVATE step 7). `sep` is `:` (`;` on Windows). The inherited values are the snapshot's `ENV`, because `Pkg.test` sets `DEPOT_PATH` only in-process.
  - `JULIA_LOAD_PATH = M * sep * (inherited JULIA_LOAD_PATH, or "")`. The empty entry expands to the default path.
  - `JULIA_DEPOT_PATH = (inherited JULIA_DEPOT_PATH, or "") * sep * P`.
  - `JULIA_PROJECT = <pinned project>`, only when D24 pinned it and `JULIA_PROJECT` was unset. Without it, an unpinned member would make `M` its active project.
  - `DISPATCH_CHECKUP_RUN = R`, then `DISPATCH_CHECKUP = "checked"` last.
  - Distributed re-serialises the in-process `LOAD_PATH`/`DEPOT_PATH`, which already carry `M` and `P`.
- **Pre-existing workers.** If Distributed is loaded and `nprocs() > 1` (found through `Base.loaded_modules`, not a dependency), refuse before any side effect (S4).
- **Record file.** `R/proc/<host>-<pid>-<rand>.toml` holds appended `[[event]]` blocks. Each block is one `write` of a complete block followed by `flush`, so the file stays valid TOML apart from a possibly truncated last block. The events:
  - `loaded`: pid, ppid, images and digests;
  - `instability`: the first occurrence per dedup key, with later counts;
  - `coverage`: once per image load;
  - `include`;
  - `identity_violation`;
  - `note`;
  - `audit`: owned methods that this process's end-of-run audit could not account for (S3.6);
  - `clean_exit`, written at atexit.

  The owner uses the same channel for itself. Appending costs about 3.6 µs per record. Events are written by a per-process **flusher**, a task that activation starts in the owner and the hook starts in a member. The recorder only signals it through a counter and never does IO (S3.1.1). A member's atexit hook drains its flusher, runs its audit, then writes `audit` and `clean_exit`; the owner drains its flusher at finalizer step 3 and audits in memory at step 4.
- **Precompile processes** (kinds B and W) never record instabilities or throw (decisions.json D12 (3)). Kind B's evaluation-time definition records go into the image's `SINK` (D05), never to `R`.
- **Merge** (finalizer step 3)
  - It accepts partial files and drops a truncated tail.
  - A process without `clean_exit` is a warning ("killed or still running"); its records count, but it never fails the run on its own.
  - Records written after the merge are lost; this is documented.
- **Members never print** from the recorder.
- **JOIN** (S4). A member's activation call compares compile-time options, re-prepends a missing redirect when the target is not yet loaded, records a note, and runs no finalizer.
- **Documented escapes.** `setenv` or `withenv` overriding `JULIA_LOAD_PATH`, nested sandboxes that drop the export after the target loaded, and remote or SSH workers all load original code unchecked.
- **Documented costs**
  - Members shadow other projects with the closure's versions (D24).
  - `ENV` differs from production.
  - Tests that must spawn production processes belong in `original=`.

**Rationale.**

- Without export, whether a descendant was checked depended on the framework and the launch: Distributed loaded the overlay, ReTestItems loaded the original under `Pkg.test` (#87), and Malt/ParallelTestRunner loaded the original.
- With export, all five processes loaded one image and reported.
- A flush at exit lost records 3 times out of 3 under ReTestItems' `terminate!`.
- The owner's hooks run after Distributed's and Malt's.
- 0 of 382 local packages use `-p`.

Evidence: `$AUDIT/D12-workers-subprocesses-w3k8`.

**Tests**

- Distributed `addprocs`, Malt/ParallelTestRunner, ReTestItems (script and `Pkg.test`) and `run(julia --project=Other)`: all load the overlay and record.
- A worker killed mid-run: its records survive and the warning appears.
- A precompile-time call adds no record.
- `julia -p 1` is refused.
- A nested activation in a member joins the run.
- `JULIA_PROJECT` export: a grandchild's active project equals production's.

---

## D16 Integrity checks

**Decision.** DispatchCheckup (DC) drops every token, digest, fingerprint and launch-state comparison. Five checks remain:

- the DispatchDoctor (DD) runtime self-test;
- template-generated image canaries;
- a load-identity check;
- the config digest;
- the `incomplete` report placeholder.

Role markers are valid only together with a live run directory.

**Requirements**

- **Deleted** (no stubs): the `CHILD_*` markers and token; 0.1's config, test-entry, snapshot, overlay, helper, original-source and environment digests (the D45 config digest kept below is a configuration key, not one of these tamper checks); the `pwd`/`ARGS`/project/`LOAD_PATH`/`DEPOT_PATH` comparisons; the helper `pathof` check; the per-module evaluated canary.
- **DD runtime self-test** (O4).
  - When it runs: in full (S3.2 (a) and (b)) at classification step 5, which precedes JOIN, so it runs in the owner and in any member that calls `dispatch_doctor`; its static part (S3.2 (a), names and method shapes) in every kind B worker before walking and once per process when a member's hook initialises. The behavioural canaries cannot run while generating output, and members rely on the image canaries.
  - What it exercises: the helpers the template calls, on fixed inputs: `type_instability` and `type_instability_limit_unions` on concrete and `Union` types, `_promote_op` on a known method, `specializing_typeof`, `checking_enabled()` including its precompile gate, `TypeInstabilityError` construction, and the `_show_warning` AD rule entry.
  - On failure: activation or the build fails, naming the helper and the DD version. The weekly CI canary runs against DD main, and a weekly `dd-floor` leg pins DD to `=0.4.29` (S5).
- **Image canaries** (D46).
  - `canary_unstable` must register an event, and `canary_stable` must not. A stable canary that registers means inference is disabled process-wide (#41), which is a configuration error.
  - The init canary runs only when `checking_enabled()`, so loading inside `allow_unstable` is not a false failure.
  - The owner's end-of-run canary, in finalizer step 2, is authoritative. Checks left disabled globally at exit are a configuration error.
  - Neither canary runs for infer-disabled roots.
- **Load identity**
  - What is checked: a `Base.package_callbacks` entry in the owner and in members, for the target and each extension (`uuid5`).
  - When it passes: a hook registration for that PkgId exists in this process, and `pkgorigins[id].cachepath` is under `P`, or source loading was allowed (D04).
  - On violation: the callback appends `identity_violation` to `R`, prints S4's message, and calls `exit(1)`. Base catches exceptions in callbacks, so it cannot throw. The finalizer then still runs, with code 1.
  - `pathof` is not an identity signal, because D13 makes it the original.
  - The finalizer also reports, as a warning rather than a failure, when `M` is no longer first on `LOAD_PATH` or `active_project() == M` (D24 documented divergences).
- **Config digest** (D45).
- **Placeholder** (S4 D22). It is written at ACTIVATE step 4, with the run id. Merged process files and guard results count only when they carry this run id.
- **Role marker.** `DISPATCH_CHECKUP=="checked"` is valid only with an `R` whose `state.toml` exists, is not closed, names the same target and has a live owner pid. There is no token, and no pid equality for members.

**Rationale.**

- The token and digests authenticated nothing (#76).
- A throwing package callback was logged and the run exited 0 (E1). `exit(1)` in the callback works, and the atexit hooks still run (E7).
- The 0.1 runtime canary failed falsely under `allow_unstable` (E2), and an untracked config stayed stale (E6).

Evidence: `$AUDIT/D16-integrity-checks-r4n8`.

**Tests**

- E1, E2 and E6 as regressions.
- `LOAD_PATH` emptied before `using` causes `exit(1)` with the report naming the violation.
- A target loaded inside `allow_unstable` passes.
- `--compile=min` (the stable canary registers) is a configuration error.
- A forged `"checked"` with a dead `R` is refused.
- A crash leaves `incomplete`.

---

## D49 Target cardinality

**Decision.** One target per process tree. The first activation fixes it. A call naming a different package fails before any state change, in the same process and in descendants. DispatchCheckup (DC) internals take a set of targets with one element, so a later tuple form can add a merged derivation without breaking anything. DispatchDoctor (DD) is unaffected.

**Requirements**

- S4's state machine (steps 6 and 7) raises the D49 error. The error names both packages and the workaround.
- The collector, `SINK` registration, `state.toml`, D24 derivation and D16 identity check are keyed by target UUID and accept a set. Each has one element in 0.2.0.
- A future multi-target form must build **one** merged `M`. Stacking one environment per target is prohibited.
- The v1 report has a single target table (S4).

**Rationale.** With stacked environments, the call order decided whether a dependency target loaded its original code (`$AUDIT/D49-target-cardinality-t4k9/exp2`). The D30 prototype silently ignored a second target, which fails open.

**Tests**

- A second target in the same process errors with no state change.
- A monorepo root that runs `Pkg.test` on a leaf with its own lines gives the error in the member.
- The internals accept a one-element set.

---

## D14 Interactive refusal (mechanism)

**Decision.** DispatchCheckup (DC) refuses to activate in a session that outlives the run. The refusal is an ordinary exception, raised before any side effect. It never activates DispatchDoctor (DD) checking in the session. S4 owns the condition's user text and the message.

**Requirements**

- **Condition**, evaluated at S4 step 3, after pure validation and the guard-marker check, and before anything else: `isinteractive() || isdefined(Main, :PlutoRunner) || isdefined(Main, :VSCodeServer) || isdefined(Main, :IJulia)`.
- **Untouched by a refusal:**
  - no `ENV` write;
  - no `LOAD_PATH`, `DEPOT_PATH` or `ACTIVE_PROJECT` change;
  - no file under `R0`;
  - no callback or atexit registration;
  - no target lookup that loads code.
- **Not refused:** piped stdin without `-i`, a `Pkg.test` subprocess started from a REPL (`julia_cmd` does not forward `-i`), the VS Code debugger, and VS Code test items.
- **The message's run line** is built from `Base.julia_cmd()`, the explicit active project (D18 snapshot rule) and the activating file. Its exact wording is S4's.
- **Follow-up.** If users ask for it later, add a subprocess delegate built on D18's command builder. In-session activation and a `finish()` API stay out (module unloading is impossible).

**Rationale.**

- Julia cannot unload the overlay.
- `"checked"` would leak into later `]test` runs in the same session.
- In record mode the verdict exists only at exit.
- Pluto workers and VS Code notebook kernels report `isinteractive() == false` (`$AUDIT/D14-interactive-repl-m4v8`).

**Tests.** S4's four tests, plus one more: after the piped `julia -i` refusal, the count of `R0` entries and `length(Base.atexit_hooks)` are unchanged.

---

## D15 Path resolution (mechanism)

**Decision.** DispatchCheckup (DC) does no entry discovery and re-runs nothing. Relative `original=` and `report=` paths are resolved once, inside the activation call, as `include` would resolve them at that point. DispatchDoctor (DD) is not involved. S4 D15 owns the user rules.

**Requirements**

- **Base.** `b = Base.source_path(nothing)`. The path is `normpath(joinpath(dirname(b), p))`, or `abspath(p)` when `b === nothing`. Results are stored absolute, so a later `cd` cannot change them. Both `Base.source_path` and `Base.include_callbacks` go through the Compat module.
- **Leak check.** `original=` entries are stored both as resolved and as realpath. The D02 include-leak callback first compares the exact string Base passes to `include_callbacks`, then the realpath. It throws before the body is evaluated and records the event in `R`.
- **Guard cwd.** `pwd()` at activation (snapshot) is the guard child's working directory.
- **Deleted.** `_entry_candidates`, `_test_entry` and `entrypoint=` are deleted, with no stub (O15).

**Rationale.**

- `source_path` inside the call is the innermost included file.
- Under `Pkg.test`, `gen_test_code` `cd`s to `dirname(test_file)` before including, so both bases agree.
- Spawned tasks lose `SOURCE_PATH`, and the existence check catches that.
- The string matches `include_callbacks` exactly, and the callback fires before evaluation.

Evidence: `$AUDIT/D15-entry-discovery-r8t5`.

**Tests**

- S4 D15's cases.
- A leak through a symlinked spelling is caught by realpath.
- A `cd` after activation does not move `report=`.

---

## D18 Flag and environment reproduction

**Decision.** DispatchCheckup (DC) starts the guard child, the only process it spawns, from `Base.julia_cmd()` plus an explicit table of the flags `julia_cmd` omits, then `--eval` with a Base-only bootstrap. The bootstrap restores the pre-activation in-process state the way `Pkg.test` does, and it never loads DC or DispatchDoctor (DD). `ENV` is the pre-activation snapshot, so the guard's own subprocesses inherit what production's would.

**Requirements**

- **Snapshot** (ACTIVATE step 1, before any change):
  - `ENV`;
  - `LOAD_PATH`, with only `@script` expanded to an absolute path; `@`, `@v#.#`, `@stdlib` and relative entries stay as written;
  - `DEPOT_PATH`, `DL_LOAD_PATH`;
  - `Base.active_project(false)`, which is `nothing` under `Pkg.test`;
  - `pwd()`, `ARGS`, `PROGRAM_FILE`;
  - the `-L` files from `JLOptions().commands`, in order and absolutised; a missing file is an activation error;
  - the flag table below.
- **Command**, in this order:
  1. `Base.julia_cmd()`.
  2. Each omitted flag, only when it differs from the default:
     - `--threads=d,i`;
     - `--gcthreads` when `nmarkthreads > 0`;
     - `--warn-overwrite=yes` (`Pkg.test` always sets it);
     - `--warn-scope=no`, `--math-mode=ieee`, `--handle-signals=no`, `--experimental`;
     - `--heap-size-hint`, `--hard-heap-limit`, `--heap-target-increment`;
     - `--task-metrics`, `--gc-sweep-always-full`, `--permalloc-pkgimg`;
     - the safepoint-straggler timeout.
  3. A fixed `--code-coverage` tracefile, passed unchanged; Julia appends to it.
  4. `--trace-compile` and `--trace-dispatch` only when they target stderr. A file target is dropped with a one-line notice, because the child would truncate the parent's file.
  5. The `-L` files.
  6. `--project=<abs path>` only when `active_project(false) !== nothing` (S4 D02 rule 4 matches).
  7. `--eval <bootstrap>`.

  `--startup-file`, `--history-file` and `--compiled-modules` are never forced.
- **`ENV`** = the pre-activation snapshot, minus every `DISPATCH_CHECKUP*` name, plus `DISPATCH_CHECKUP_RUN="guard:<owner pid>"` (S4 D31; conflict 16). `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` are restored to their pre-activation (snapshot) values, unset included.
- **Activation in the guard child is inert.** Resolved (default). An activation call reached inside the guard child or any of its descendants sees the `guard:<pid>` marker and is inert (S4 state machine step 2): it returns `nothing` and starts no nested run, so the guard keeps running against the original code.
- **Bootstrap** (plain Base code, after `Base.load_path_setup_code`):
  1. `Base.exit_on_sigint(true)`.
  2. On Linux, `prctl(PR_SET_PDEATHSIG, SIGKILL)`; then exit at once if `getppid()` is not the owner pid.
  3. Restore `DEPOT_PATH`, `DL_LOAD_PATH`, `LOAD_PATH` and `ARGS`, and `cd` to the snapshot cwd. `PROGRAM_FILE` stays `""` (S4, D50; D18's restore is not used).
  4. For each `original=` file: run `Base.include(Main, file)` inside `@testset "original: <relpath>"`, with Test obtained through `Base.require` so no `Test` binding is added. Use a per-file `try`/`catch`, continue past failures, and append the result (`passed`/`failed`/`errored`) to `R/guards.toml`. The bootstrap text carries the path of `R` and the file list as literals; the guard child's `ENV` carries neither. Files with no result are `not_run`.
  5. Inverse identity: if the target is loaded, its cachepath must not be under `R0`, and `Base.locate_package(target)` must be the original entry.
  6. Exit 1 if any file did not pass.
- **Process**
  - `stdin=devnull`; `stdout`/`stderr` inherited, both flushed first (#59); cwd from the snapshot.
  - The finalizer catches `InterruptException` around `wait`, kills the child, records `interrupted` and calls `exit(130)`.
  - The reaper (DC's second and last atexit hook, D30) only kills a guard child that is still alive after a signal.
  - macOS has no PDEATHSIG. A parent `SIGKILL` can orphan the child there (documented). Windows is experimental.
  - Activation fails closed on any operating system other than Linux, macOS and Windows (S4 step 5). Resolved (default).
- **Drift test.** `fieldnames(Base.JLOptions)` is pinned for 1.13, with each field classified as forwarded by `julia_cmd`, reconstructed, or deliberately dropped.

**Rationale.**

- `julia_cmd` omits threads, `--project`, `-L`, `--warn-overwrite`, the heap flags and fixed coverage files (base/util.jl:171-252).
- A prototype builder reproduced the `Pkg.test` state identically, and a flagged direct script identically apart from the `@script` spelling. Post-activation exports did not leak.
- Coverage files append correctly. A trace file was corrupted when shared.
- Relative `LOAD_PATH` entries resolve lazily against the cwd, so they are kept.

Evidence: `$AUDIT/D18-flag-env-propagation-r4k9`.

- Under `-e`, Ctrl-C reaches the hook as code 1 unless `exit_on_sigint` is flipped, and the runner's `try`/`catch` would swallow it.
- PDEATHSIG kills the busy child of a parent that was killed with `SIGKILL`.

Evidence: `$AUDIT/D50-guard-child-contract-x7k2`.

**Tests**

- The `Pkg.test` parent and the guard child match on `PROGRAM_FILE`, the project, `load_path()`, `DEPOT_PATH`, `DL_LOAD_PATH`, cwd, `ARGS`, `ENV` (modulo the marker) and flags.
- A direct script with `-t 4 --warn-overwrite=yes --heap-size-hint=2G --gcthreads=3 -L setup.jl` and an `@script` load path.
- `-p 2` is refused at activation (D12), so `--procs` and `--machine-file` never reach the guard child.
- Fixed-LCOV append.
- A trace-file notice.
- SIGINT and SIGTERM during the guard phase leave no orphan; a parent `SIGKILL` leaves no orphan on Linux.
- The JLOptions drift test.

---

## Straightforward fixes in this section's scope

| fix | here |
|---|---|
| #30 entryfile; #104 overlay `Project.toml` | D24, D13 |
| #31 stale report | D16 placeholder (conflict 19); the "fresh passed report" rule is moot under D30 |
| #35 orphaned processes | Only the guard child remains: reaper hook, PDEATHSIG, interrupt catch (D18). This replaces the inherited-pipe watchdog |
| #40 targets in DC's closure; #44 repeated activation | S4 state machine |
| #41 inference disabled process-wide | stable canary (D16) |
| #52 path spelling | `R0` realpath'd once (D17+D47) |
| #58 extension entry lookup; #23 extension identity | D13 |
| #59 flush before spawn; #60 target never loaded | D18; finalizer step 5 |
| #75/#120 DD warnings in output | worker logger filter and captured build output (D04) |
| #78 canary leak; #80 Base internals | one hook module (D46); Compat module |
| #119 `@main` | by construction (D30) |
| #39 lesson (`@__DIR__` baked in) | D04 |
| #56 optional include; #57/#63/#29 tree walk | **moot** under D13 (no snapshot, no tree copy) |
| #66–#69 test hygiene | each fixture gets its own `DISPATCH_CHECKUP_DEPOT` (S5) |

---

## Open points (all resolved)

1. **`@depot` relocation layout** (D17+D47). **Resolved (default).** The sibling layout (`O` beside `P` in `K`, no mirrors) is adopted. The P1 matrix above is its acceptance gate: a failing cell becomes a documented rebuild case, and mirrors return only if no mirror-free layout passes.
2. **Build-time `DISPATCH_CHECKUP_RUN` read. Resolved.** S4 D31 now carries the carve-out for D46's gate and failure files, which cannot affect generated code. The D45 reuse-across-`R` test enforces it.
3. **Guard-child details versus S4's user view. Resolved.** S4's user rules now follow D18's verified rule: `--project` only for an explicit project, and only `@script` expanded.
4. **Lock-free persistent writes. Resolved (default).** DC's persistent writes stay lock-free (temporary file then rename, write-once `env/`), with no FileWatching, per O14. The P1 concurrency test verifies this. Only if that test finds a race would adding the FileWatching stdlib go back to the owner, as a change to O14.
5. **`--compiled-modules=strict`. Resolved (default).** Accept and document: DC never forces a flag, so a first checked run in strict mode errors with Base's own error because no private image exists yet. A run under the default `yes` populates `P`, and later strict runs load from it (D04).
6. **`JULIA_PROJECT` export after a fallback pin. Resolved (default).** The export stays as D12 specifies: only when D24 pinned the project and `JULIA_PROJECT` was unset. D12's test (a grandchild's active project equals production's) is its acceptance check in P1.
7. **Lazy builds in `U`. Resolved (default).** They are allowed and reported as `lazy` for dependents and third-party extensions only. They land under a distinct cache slug that carries the D45 preference and never overwrite a production file in place. The target and its extensions are refused (D46 gate, fail loud, documented divergence). S5 C-12 says zero files in `U/compiled` for the target and its extensions. Measure the eviction pressure on production caches in the D26 corpus.
8. **Residual risks. Resolved (default): documented, not fixed.** A libc `exit(0)` false pass; peak memory during the guards; a macOS orphan on parent `SIGKILL`; Windows checked runs are experimental. Activation fails closed on any operating system other than Linux, macOS and Windows.

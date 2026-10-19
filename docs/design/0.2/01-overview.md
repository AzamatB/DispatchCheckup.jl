# S1 Overview and decision log

DispatchCheckup 0.2 redesign specification. Sections: **S1** Overview and decision log (this file), **S2** Architecture, **S3** Checking semantics, **S4** Public API and user contract, **S5** Engineering plan, **S6a** JLL targets. The consumer migration plan (S6b) is private and maintained outside this repository; the spec cites it as "the private consumer migration plan (S6b)".

Conventions:

- "must", "must not", "should" and "may" are normative.
- DispatchCheckup is written DC and DispatchDoctor is written DD after their first use in a section.
- Keys: `O*` are owner decisions and are authoritative. `D*` are review decisions, settled by the owner-accepted defaults unless an `O*` item overrides them. `SF` is the set of straightforward fixes. `C0`–`C23` are the cross-decision conflict resolutions, numbered by their 0-based index in `decisions.json` `.conflicts`. Other sections cite them as `CN` or "conflict N"; both mean `.conflicts[N]`.
- Precedence is owner items first, then accepted defaults, then the text of `decisions.json`. Any text in `decisions.json` that conflicts with a final decision is void, including challenger recommendations.
- `$AUDIT` = the maintainer's local review archive (not part of this repository). It holds the reviewer repros, `decisions.json` and `review.json`; `review.json` lists the 123 verified defects, cited as `#N`. Evidence is cited as `$AUDIT/<directory>`; evidence from the private consumer repositories is cited as `$AUDIT (consumer inventory)`.
- **Resolved (default)** marks a point that was open for the owner and is settled by the lead reviewer's recommendation, which the owner accepted for every item the owner did not decide. Points still open for the owner are listed in §7.
- The consumers are the owner's internal consumer repositories. They are private, except GodelaAMGX_jll, which is public; per-repository detail lives in the private consumer migration plan (S6b).

---

## 1 O0 Purpose and scope

**Decision.** DispatchCheckup (DC) 0.2 is an internal tool for the owner's own packages, developed in the public GitHub repository `AzamatB/DispatchCheckup.jl`. It runs DispatchDoctor (DD) `@stable` return-type checks against one target package while that package's own test suite runs. It never edits the package's production source.

**Requirements**

- DC must resolve, precompile and import on any Julia ≥ 1.13 that its compat allows. It must run checks only on Julia 1.13.x, the validated window. Outside that window, `dispatch_doctor` must throw a clear error before it has any side effect (O14).
- DC is distributed as a URL source. Consumers declare `[sources] DispatchCheckup = {url = "https://github.com/AzamatB/DispatchCheckup.jl", rev = "main"}` and track `main` on purpose. Path sources are used only for development and for DC's own GPU tier.
- 0.2.0 must not be registered, in General or in any private registry. No 0.2 requirement may exist only to satisfy registration: no AutoMerge gates, no LTS floor, no mandatory AI disclosure.
- The 0.2.0 scope is:
  - the six-keyword activation call (O6);
  - in-process activation (D30);
  - persistent instrumented images (D04, D17, D47);
  - the owned check wrapper (O4);
  - record mode (D03);
  - `original=` guards (D02, D50);
  - descendant aggregation (D12);
  - the versioned report (D22);
  - the method-table audit (D44).
- The known users are the owner's internal consumer repositories, all private except GodelaAMGX_jll. The owner counted 13; the local scan (S5 D27, `$AUDIT (consumer inventory)`) finds one more, giving 14 internal consumer repositories (17 packages) with a `"0.1.2"` compat entry. **Resolved (default):** all 14 repositories (17 packages) are in scope and are migrated as part of the release (the private consumer migration plan, S6b).

**Rationale.** This is owner decision O0. All consumers declare `DispatchCheckup = "0.1.2"` with `rev = "main"` sources (their `Project.toml` and `test/Project.toml`). Many recommendations in `decisions.json` were driven by registration: the 1.10 floor, the stub module, General's AutoMerge and LLM policy. Those parts are void (D19, D27, D38).

**Tests**

- The contract tier (D36) resolves, precompiles and imports DC on Julia 1.13 on Linux, macOS and Windows.
- A unit test drives the window predicate with versions outside 1.13.x. It asserts the error text and that the call left no state behind.
- The weekly pre/nightly canary job also runs one unpatched activation and asserts the window error.

---

## 2 O1 Hard requirement and Design A

**Decision.**

The **hard requirement** (HR): commenting out these two lines at the top of `test/runtests.jl` makes everything run as if DC did not exist.

```julia
import DispatchCheckup
DispatchCheckup.dispatch_doctor(:MyPackage; unstable = (:foo, :bar))
```

"As if DC did not exist" means exactly the D51 contract (S4): runtime equivalence plus an additive-only resolution delta, published as a compat table, on Julia 1.13+.

**Design A** is the only 0.2 design. Its rules:

- **A1 Ordinary package.** DC is an ordinary, eagerly loading package. `import DispatchCheckup` loads its whole implementation and its dependencies. There is no lazy facade, no regex-patched helper overlay and no `invokelatest` bridge into a lazily included implementation.
- **A2 One touch point.** No test code other than the two lines references the `DispatchCheckup` module. `dispatch_doctor` is the only public name. `test_original` and `source_root` are deleted (O15).
- **A3 Guards in the call.** Guard files are declared in the activation call (`original=`). Test files skip them in checked runs with exactly:

  ```julia
  get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("test_guards.jl")
  ```

- **A4 Inert presence.** This is the review's "Design A item 4". DC stays a declared test dependency, either in `[extras]`/`[targets]` or in `test/Project.toml`.
  - It must resolve, precompile and import wherever the target's tests run.
  - Apart from Julia's own precompile cache for DC, importing it must not write files, and must not change `ENV`, `LOAD_PATH`, `DEPOT_PATH`, preferences, `atexit` hooks, `Base.package_callbacks` or `Base.include_callbacks`.
  - Top-level code must not touch DD internals or version-specific Base internals. Only code that runs at activation, in build workers, in image hooks or inside generated wrappers reaches them (file rules in S2 "Source layout"). There are two exceptions, both from S3.1 R8: the `isdefined`-guarded definition of DC's `_show_warning(::Site, …)` method, which build workers and members need from DC's image, and the template-generator precompile workload, which runs only inside the window and inside `try`/`catch`, so DD drift cannot break DC's precompilation.
- **A5 Guards against the original.** The activating process runs the guard files against the original code, in one fresh ordinary child process after the checked suite (D02, D50).

**Requirements**

- The checked run happens inside the activating process (D30). Nothing re-runs `runtests.jl`.
- Every DC behaviour must follow from the activation call. Setting `DISPATCH_CHECKUP` alone has no effect while the lines are commented out, because DC is not loaded.
- A checked run must never write to:
  - the target's checkout;
  - its test `Project.toml`, `Manifest.toml` or `LocalPreferences.toml`;
  - the user depot's production cache entries for the target (D51 history independence). No production cache file of any package is overwritten in place: a dependent built lazily after activation adds its own cache file under a distinct slug (§7 item 2).
- With the lines commented out, the only permitted difference is D51's additive manifest delta (DC, DD, MacroTools, Preferences, stdlibs). That delta holds only under D51's compat table.

**Rationale**

- 0.1.2's compat `MacroTools = "0.5.16"` re-resolved a user's MacroTools from 0.5.15 to 0.5.16 even with both lines commented out. With DD-equal compat ranges, the loaded modules, `pkgorigins` and cache files were identical (`$AUDIT/D26-test-strategy-m3k8/out`, `$AUDIT/D20-dependency-footprint-m3q8/runs`).
- In-process activation works under `Pkg.test` with the `[extras]`/`[targets]`, `test/Project.toml` and `[workspace]` layouts. The image is reused across runs, and the guard child runs from `atexit` (`$AUDIT/D30-process-model-k7w2`).
- The inert-import facade is what required the helper overlay and the bridges (#39, #61). Design A removes that defect class.

**Tests**

- Twin harness (D26): run `Pkg.test` on a generated fixture twice, (a) with the lines commented out and DC declared, and (b) with DC removed. Assert the D51 observables, then the history sequence unchecked → checked → unchecked.
- Import inertness: before and after `import DispatchCheckup`, the following are equal:
  - snapshots of `ENV`, `LOAD_PATH`, `DEPOT_PATH` and the active project;
  - the `atexit` hooks, `package_callbacks` and `include_callbacks`;
  - the file listing of every depot.
- The public names of `DispatchCheckup` are exactly `dispatch_doctor`.
- Guard idiom:
  - a guard file listed in `original=` is never evaluated in the checked process (D32 makes a leak an error);
  - it runs exactly once, in the guard child, against the original package (its production cache, never the private depot).

---

## 3 Non-goals for 0.2

- **Registration.** Neither registry. AI disclosure is optional (D38).
- **Julia before 1.13.** No checks outside 1.13.x and no stub module. Julia 1.14 support is canary-only.
- **Inert import.** `import DispatchCheckup` loads DD. Only commenting out both lines, or the D40 gate, is "absent".
- **Child relaunch, entry discovery, `entrypoint=`.** There is no re-run of the test entry (D30, D15).
- **A copy of the package.** No tree copy, snapshot, symlink mirror, tamper digest, token or fingerprint (D13, D16). The DD-active self-test and a load-identity check remain; the D45 config digest stays as a configuration key, not a tamper check.
- **Runtime acceptance of known instabilities.** There is no `waive=`, `allow=`, `exclude=` or baseline file. The only way to accept a definition is `unstable=`, which leaves it unwrapped (O6).
- **User-extensible macro classification.** There is no `macros=`. The macro table is built in and vetted (D06, D07).
- **Other keywords.** There is no `share_assets=` and no keyword beyond the six in O6.
- **Several targets in one process** (D49).
- **Interactive sessions.** REPL, Pluto, VS Code notebooks and IJulia are refused (D14).
- **A public out-of-tree runner API** (D39).
- **JSON reports** (D22).
- **Re-enabling inference** in modules that disable it, JLLs included (O10, D08).
- **Load-time detections.** Instabilities in code that runs only in module bodies or package macros at build time are not detected unless tests call that code. This is parity with native DD (C14).
- **Crash safety.** No verdict survives a hard crash, an OOM kill or a libc `exit`. This is documented (D30).
- **A sandbox.** DC is not a security boundary. Tested code keeps its ordinary filesystem permissions.
- **Migration aids.** No stubs and no error hints for removed API (O15).
- **Windows checked runs as a supported feature.** They are experimental; only the contract tier is supported on Windows (D25).
- **Other operating systems.** **Resolved (default):** activation fails closed on any OS other than Linux, macOS and Windows (D25).
- **Building the target after activation.** **Resolved (default):** the D46 gate refuses to build an instrumented image of the target or of one of its extensions after activation, and fails loud. This is a documented divergence: for example, an extension triggered late or an environment created by the tests cannot load the target in a checked run (§7 item 2).

---

## 4 Glossary

S2 and S3 define these terms normatively; S1 gives the working meaning.

- **Target.** The single package named in `dispatch_doctor(:MyPackage)`, identified by its PkgId as resolved from the active environment. Its *owned modules* are:
  - the root module;
  - every submodule;
  - every extension of the target. An extension is owned when its PkgId is `Base.uuid5(target uuid, extension name)` (SF #23).
- **Activating process.** The process that evaluates the activation call, normally the `Pkg.test` test process. It builds the images and owns the verdict, the report, the guard child and the final exit status.
- **Checked run / ordinary run.**
  - A *checked run* is the activating process from the activation call to exit, plus its descendants.
  - An *ordinary run* is a run with the lines commented out or gated off. The guard child is also an ordinary run.
- **Injected environment.** A minimal, content-addressed environment that is prepended to `LOAD_PATH` (D24). It has three files:
  - `Project.toml` lists the target under `[extras]` only, so name lookup stays with the user's active project;
  - `Manifest.toml`'s target record points at the overlay and adds DD and DC to the target's deps;
  - `LocalPreferences.toml` carries the compile-time config table (D45).
- **Overlay.** A per-checkout directory inside the private depot. It holds exactly:
  - a byte-identical copy of the target's `Project.toml`;
  - the entry shim;
  - one shim per extension, at the original relative path.

  No source file is copied (D13).
- **Shim.** A generated entry file in the overlay. It first rewrites `Base.pkgorigins` so `pathof` and `pkgdir` report the original checkout. Then it includes the original source in place through DC's include mapper.
- **Walker.** The syntax core kept from 0.1's `instrumentation.jl`: the traversal, the call and signature rewriting, the native-include rewriting, the include mapper and the name helpers (D01). It turns each eligible definition into a check wrapper.
- **Check wrapper.** DC's own per-definition code, generated from the template derived from DD 0.4.29's `_stabilize_fnc` (O4). It infers the return type through DD's runtime helpers, records or throws on an instability, and runs the real body.
- **Private depot.** `<first user depot>/compiled/v1.13/.dispatchcheckup/`, which `DISPATCH_CHECKUP_DEPOT` can override (D47).
  - It holds the overlays, the instrumented images, the injected environments and the default report.
  - Each overlay key is (name, uuid, crc32c(realpath root), layout version), recorded in `key.toml`.
  - It is first on `DEPOT_PATH` only during the up-front build, and last at runtime (D17).
- **Image.** A precompiled cache file (`.ji` plus pkgimage) for the instrumented target, for one of its extensions, or for a dependent compiled against them.
  - Images of the target and its extensions live only in the private depot, and are never built after activation (D46 gate). Dependents also build there at activation. A dependent built lazily after activation is allowed: it lands in the user depot under a distinct cache slug (it carries the D45 preference), never overwrites a production file in place, and is reported as `lazy` (S2 D17+D47).
  - They are reused across runs while Base's staleness checks and the config preference match (D04, D45).
- **Precompile worker.** A process Base spawns to build an image (`jl_generating_output() == 1`). The walker runs there. A worker never records instabilities and never throws checks.
- **Private submodule.** The hidden module `var"#DispatchCheckup"`, inserted as the first statement of each image root: the target root module and each extension (D46). It holds the record sink, the image canaries and the load hook. The load hook (its `__init__`) does the `pkgorigins` rewrite, registers the sink, installs the include observer and runs the canaries. The DD self-test runs in full at activation, and its static part in build workers and once per member process; the load-identity check is a package callback, installed at activation in the activating process and by the hook in members (S2 D16, D46).
- **Run directory.** The per-run directory named by the private `DISPATCH_CHECKUP_RUN`. It holds the run state (target, root pid, injected environment) and one durable record file per process (D12, D31).
- **Guard file.** A file listed in `original=`. It must only ever run against the original code.
- **Guard child.** The single fresh ordinary Julia process that the activating process starts from its finalizer `atexit` hook, after the suite and validation (D02, D18, D50).
  - It reproduces the pre-activation flags, `LOAD_PATH`, `DEPOT_PATH`, active project, cwd and `ARGS`.
  - Its `ENV` is the pre-activation snapshot minus every `DISPATCH_CHECKUP*` name, plus the marker `DISPATCH_CHECKUP_RUN=guard:<pid>`, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored to their pre-activation values.
  - It includes the guard files into `Main` in order.
  - Its bootstrap loads neither DC nor DD. If a guard file itself reaches the activation lines (shared setup), the call is inert in the guard child and in all its descendants (S4 state machine step 2).
- **Descendant.** Any Julia process started, directly or transitively, by the checked process during the suite: Distributed, ReTestItems, ParallelTestRunner or Malt workers, and `run(julia ...)`. Precompile workers and the guard child are not descendants.
  - Descendants inherit the exported redirect and load the instrumented images.
  - They append records to the run directory.
  - They never run guards or write the report.
- **Record.** A fact emitted at evaluation time (D05) or by the method-table audit (D44). It covers either:
  - one definition site: its class, module, line span and the selectors that matched it; or
  - one instability: the definition site, the specializing signature, the inferred type, call sites, testset, task and pid.

  Records made in a precompile worker are serialized into the image.
- **Instability.** A checked call whose inferred return type fails the checker: it is not concrete, or it is a `Union` larger than the effective union limit.
- **Blind spot.** Code that may define methods DC could not check, and that no rule accounts for:
  - definitions under unvetted decorators;
  - opaque method-defining macros;
  - top-level `eval` of non-literal code;
  - methods the audit finds that no record accounts for.

  `require_all=true` counts only blind spots that are not listed in `unstable=` (D11; Resolved (default), §7 item 11).
- **Limitation.** A definition that DD declines by design, or that a vetted `:skip` entry of DC's macro table leaves unwrapped (S3.7), and that DC therefore cannot check. Examples: `Foo{T}(...)` constructors, functors and callable objects, nested-qualified names, `@generated` functions. Limitations are reported with locations and per-category counts, and are never counted.
- **By-design skip.** A definition left unchecked on purpose (D08): left unwrapped, or wrapped but inert at run time (DD-ignored methods, and wrappers defined before a late inference-disabling flag, S3.4). Reported, and never counted or an error. The cases:
  - `__init__` in every owned module;
  - methods for which DD's `ignore_function` is true (iterate, getproperty and setproperty!, as DD decides);
  - modules with `jl_get_module_infer == 0`, which by default includes JLLs (JLLWrappers' `disable_optimization` preference);
  - `@nospecialize` methods;
  - PrecompileTools workload bodies;
  - top-level load-time lambdas and do-blocks.

  Inner constructors are checked, not skipped.
- **Inactive.** An `unstable=` entry or a definition whose only matches are in code that was not evaluated this run, such as an unloaded extension or a dead branch. It is reported and is not an error (O6, D05).

D08 and D11 classify some forms differently. Where they disagree, the owner defaults decide:

- DD-ignored methods and `@nospecialize` methods are by-design skips;
- the other forms DD declines are limitations;
- nested closures are informational;
- inner constructors are checked.

---

## 5 Decision log

The **Spec** column names the section that specifies the decision normatively. A second section in parentheses also depends on it. `S6b` in this column is the private consumer migration plan, maintained outside this repository.

### 5.1 Owner decisions

| Key | Topic | Final decision (one line) | Decided by | Spec |
|---|---|---|---|---|
| O0 | Audience and scope | Internal tool in a public repo. Julia 1.13+. Consumers track `rev="main"`. No registration (General or a private registry) and no AI disclosure needed. | owner | S1 (S6b) |
| O1 | Hard requirement, Design A | Commenting out the two lines gives an as-if-absent run. DC is an ordinary eager package, and no other test code references it. Guards go in `original=` and are skipped with the `DISPATCH_CHECKUP == "checked"` idiom. The activating process runs the guards against the original code. | owner | S1 §2, S2, S4 |
| O4 | Own the wrapper | DC generates its own per-definition wrapper from a template derived from DD 0.4.29 `_stabilize_fnc` (Apache-2.0), calling DD's runtime helpers. It never macroexpands or patches `@stable`. Recorder, AD transparency, Type-keyword gate, long tuples, simulator lines, `Base.:!` and inner constructors are template parameters. Load-time helper self-test plus a DD-main CI canary. | owner | S3 (S5) |
| O6 | API | `dispatch_doctor(pkg::Symbol; unstable=(), original=(), union_limit=1, require_all=false, mode=:record, report=nothing)`. `unstable=` has DD `@unstable` semantics (not wrapped, not checked) and is the only selection list. Its grammar has forms (a)–(d), validated at load. | owner | S4 |
| O10 | JLL targets | JLL targets keep loading: JLLWrappers' generated platform includes are mapped. Inference is never re-enabled. Modules with inference disabled are by-design skips, and the report says nothing was checkable there. A flag set late in the module body is also a by-design skip, never a configuration error, and wrappers defined before it are inert (S6a refines D08). GodelaAMGX_jll's checked test must keep passing. | owner | S6a (S3) |
| O14 | Dependencies, compat, window | `[deps]` are DD, MacroTools and TOML, plus Preferences only if its public API is used. Pkg, SHA and UUIDs are dropped. Compat: julia `"1.13"`, DD `"0.4"` with an activation check `pkgversion(DD) >= 0.4.29` that fails closed, MacroTools `"0.5"`, Preferences `"1"`, TOML `"1"`. Checks run only on 1.13.x. | owner | S5 (S4) |
| O15 | Release | v0.1.2 is tagged at 2fd0449. 0.2 lives on `redesign-0.2` and merges to `main` as 0.2.0 (tag v0.2.0). `test_original` and `source_root` are deleted with no stubs or hints. The consumers (13 per the owner; 14 internal consumer repositories, 17 packages, in the scan, all in scope) migrate in step with the merge. | owner | S5 D27, S4, S6b |

Owner items keep the owner's numbering. **Settled:** O0, O1, O4, O6, O10, O14 and O15 are the only owner items for 0.2. O2, O3, O5, O7–O9 and O11–O13 do not exist for this spec.

### 5.2 Review decisions

| Key | Topic | Final decision (one line) | Decided by | Spec |
|---|---|---|---|---|
| D01 | Rewrite strategy | Partial rewrite. Keep the ~520-line syntax core of `instrumentation.jl`; replace its ~420-line bookkeeping layer and the whole shell. Define the shell–walker seam (typed config, record channel) first. Phases: P1 shell plus seam with the walker frozen, P2 one PR per walker policy, P3 recorder, audit and corpus. About 17–25 developer-days for the core code; S5's bottom-up plan, which adds contract tests, CI, corpus, docs and the migration, estimates 45–63 (S5 open point 8; open for the owner, §7 item 13). | default | S5 |
| D02 | Guards | `original=` files are standalone. They run in order in one fresh ordinary process after the suite and validation, even when the suite failed, and are skipped on interrupt. Final status is the first nonzero of (suite, validation, guards). | default (O1) | S4 (S2 D30, D18) |
| D03 | Checking mode | `mode=:record` (default) runs the real body, records every instability and fails at the end with the full list. `:error` throws `TypeInstabilityError` at the call. Mode is a runtime switch, so one image serves both. Never throw in generator or pure contexts. The recorder is routed through DD's `_show_warning`. | default (O6) | S3 |
| D04 | Load mode | A persistent precompiled instrumented image, built eagerly at activation with its output captured. Base decides fallbacks. A load-mode assertion checks the result. | default | S2 |
| D05 | Record timing | Records are produced at evaluation time into the private-submodule sink and serialized into the image. Expansion and mapping have no side effects. Dead branches are reported as inactive. | default | S3 |
| D06 | Decorators | Deny by default, using a vetted built-in classification table with no user keyword. An unknown decorated definition is left unwrapped and recorded as a blind spot, which `unstable=` can acknowledge. | default (O6) | S3 |
| D07 | Block macros | Built-in transparent table (`@muladd`, `@fastmath`, `@inbounds`, `@views`, `@reexport`, …). DD's `@stable`/`@unstable` blocks are stripped and their regions honoured; an `@unstable` region acts as `unstable=` for its contents. Unknown block macros are opaque: includes are still mapped and definitions recorded at their own lines. | default | S3 |
| D08 | Default scope | By-design skips are those in §4. Inner constructors stay checked. | default | S3 |
| D09 | Source annotations | Source `@stable` annotations are re-wrapped by the DC template. Their union limit is honoured, their mode overridden, and DD's region rules mirrored exactly. | default (O4) | S3 |
| D10 | `unstable=` matching | Syntactic matching, decided at emission and counted only from evaluation-time records. Grammar (a)–(d) per O6. No match in walked source is an error with nearest candidates; matches only in unevaluated code are inactive; a bare name matching in several modules is noted. **Resolved (default):** a listed definition that carries its own explicit source `@stable` keeps DD's native check, as in production (DD's `@unstable` is a no-op that only hides code from implicit wrapping; an explicit author-written `@stable` still applies). Members of a source `@stable` block that are listed in `unstable=` are emitted unwrapped. | owner (O6) | S4 (S3) |
| D11 | `require_all` | Counts only blind spots not listed in `unstable=`. DD limitations are reported with locations and counts, and are never counted. Literal `@eval` bodies are instrumented. **Resolved (default)** as the reading of O6 (§7 item 11). | default (O6) | S3 (S4) |
| D12 | Descendants | `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `DISPATCH_CHECKUP_RUN` are exported to every descendant. Each process writes durable per-process record files, which the activating process merges at exit. Distributed workers that exist before activation are an error. | default | S2 |
| D13 | Overlay and identity | Minimal overlay (§4). The shim rewrites `Base.pkgorigins` and includes the original sources in place, so `pkgdir` and `pathof` report the checkout. No tree copy, snapshot, symlinks or fingerprints. | default | S2 |
| D14 | Interactive sessions | Refuse REPL, Pluto, VS Code notebooks and IJulia before any side effect, with actionable remedies. | default | S4 (S2) |
| D15 | Paths | No entry discovery. Relative `original=` and `report=` paths resolve against the activating file (`Base.source_path(nothing)`), or against pwd when there is none. | default | S4 (S2) |
| D16 | Integrity checks | Drop the token, digest, fingerprint and launch-state checks. Keep the DD-active self-test (now the O4 runtime-helper self-test) and a load-identity check, plus the D46 image canaries, the D45 config digest and the D22 `incomplete` placeholder. | default (O4) | S2 |
| D17 | Depot layout | The private depot is first on `DEPOT_PATH` only during the up-front build and last at runtime, so Scratch, artifact and log writes land in the user depot. No mirroring yet: S2 adopts a sibling overlay layout (`O` beside `P`, never inside it) provisionally, and a P1 prototype settles whether `dev/` and `packages/` must be mirrored (open point 1). | default | S2 |
| D18 | Flag and env propagation | The guard child gets `Base.julia_cmd()`, a table of the flags `julia_cmd` omits, `--project=<snapshot>` when the activating process had an explicit project, and a Base-only `-e` bootstrap that restores the pre-activation `DEPOT_PATH`, `DL_LOAD_PATH`, `LOAD_PATH`, cwd and `ARGS`. **Resolved (default):** its `ENV` is the pre-activation snapshot minus every `DISPATCH_CHECKUP*` name, plus `DISPATCH_CHECKUP_RUN=guard:<pid>`, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored to their pre-activation values (§7 items 3 and 4). | default | S2 |
| D19 | Julia window | Compat julia `"1.13"`. The runtime window 1.13.x is enforced at activation, before any side effect. No 1.10 floor, no stub or windowed module, no shipped override. | owner (O14) | S5 (S4) |
| D20 | Dependency footprint | Minimal `[deps]` per O14. Pkg, SHA and UUIDs move to `[extras]` if tests need them. Compat copies DD's own ranges. Base replacements: `Base.UUID`, `Base.uuid5`, `Base._crc32c`. **Resolved (default):** activation also fails closed unless `pkgversion(MacroTools) >= 0.5.12`, re-measured after the walker refactor (§7 item 7). The Aqua and CheckConcreteStructs `[sources]` fork pins in `[extras]` stay as they are; switching to registered versions is out of scope for 0.2. | owner (O14) | S5 |
| D21 | DD coupling | DD is used only as a runtime library under the owned template (O4). Compat DD `"0.4"` with a fail-closed ≥ 0.4.29 check at activation. No DD internals at top level. Helper self-test at load and a weekly DD-main canary. DD generator fixes are ported by hand. **Resolved (default):** the `Type{<:Type}` singleton handling (#82) is adopted as template divergence 8; it matches production on Julia 1.13.2 with DD 0.4.29 (S3.1.5). | owner (O4, O14) | S3 (S5) |
| D22 | Report | Versioned TOML report, schema v1. An `incomplete` placeholder is written at activation and the final write is atomic. It lists instabilities with signatures and sites, and unloaded extensions. `report=nothing` writes a default file in the private depot and prints its path; `"path"` is relative to the activating file; `false` writes nothing. | default (O6) | S4 |
| D23 | Special cases | Long-tuple handling (≥ 32 positional arguments) is a generic template parameter with a CPU zero-allocation contract test. CUDA overlay macros (`@device_override`, `@overlay`, …) are `:skip` entries in the built-in macro table: limitations, never counted (S3.7). JLL handling follows O10. | default (O10) | S3, S6a |
| D24 | Environment derivation | A minimal environment is prepended to `LOAD_PATH`. The active project is pinned, the closure is derived with Base's own resolvers, and the environment directory is content-addressed. | default | S2 |
| D25 | Platforms | Resolve, precompile, import and gate-off contract on Linux, macOS and Windows (Julia 1.13). Checked runs are supported on Linux and macOS and experimental on Windows. **Resolved (default):** activation fails closed on any other OS. | default | S5 |
| D26 | Test strategy | Twin harness for the HR. Triage the existing tests for removed behaviour and write fail-closed contract tests first. The review repros become regression tests. A weekly real-package corpus runs. **Resolved (default):** public CI runs only public packages; the private consumer repositories join the corpus only on the maintainer host (manual or cron there), so no token is stored in public CI. | default | S5 |
| D27 | Distribution and release | No registration. 0.2 merges from `redesign-0.2` to `main` as 0.2.0 and is tagged v0.2.0. **Resolved (default):** the merge is a merge commit, not a squash. The consumer migration is coordinated with that merge; its rollout path is open for the owner (§7 item 12). | owner (O0, O15) | S5 (S6b) |
| D28 | `source_root` | Closed: deleted outright. `pkgdir(MyPackage)` reports the checkout in checked runs (D13). | owner (O15) | S4 (S6b) |
| D29 | API surface | Exactly the O6 signature; it returns `nothing`. Keywords have no type annotations and are checked by hand (an `ArgumentError` names the keyword); an unknown keyword is a `MethodError`. A repeated call with equal options is a no-op, with different options an error. A failed call leaves no state. | owner (O6) | S4 |
| D30 | Process model | In-process activation. Prepend the generated environment, build the images, set `DISPATCH_CHECKUP=checked`, and register the finalizer `atexit` hook, which validates, writes the report, runs the guards and sets the exit status. No child relaunch. **Resolved (default):** two `atexit` hooks are accepted; the second is the D50 reaper, which only kills a guard child still alive after a signal and does no validation, reporting or guard work. | default | S2 |
| D31 | Env contract | User values of `DISPATCH_CHECKUP` are unset, `""` or `"on"`; `"checked"` is set only by DC. `DISPATCH_CHECKUP_RUN` is private. The `DISPATCH_CHECKUP_` prefix is reserved. `DISPATCH_CHECKUP_DEPOT` is documented. **Resolved (default):** unknown `DISPATCH_CHECKUP_*` variables are ignored by DC and listed in the banner; consumers may keep reading their own variables (for example a report-path variable) in test code. | default | S4 |
| D32 | Guard tools in the checked run | Analyzers are neutralised by D13's original identity. Warn on the Aqua `stale_deps` blind set. Error when a file listed in `original=` is included in the checked process. | default | S4 |
| D33 | Removed API | `test_original`, `source_root` and `entrypoint=` are deleted outright, with no stubs or error hints. The CHANGELOG and README cover the idioms the consumers use. | owner (O15) | S4 (S6b) |
| D34 | Test migration | Merged into D26. | default | S5 |
| D35 | Docs structure | Demoted to SF: the README is rewritten as a user guide (#70, #71, #92, #95, #116). | default | S5 |
| D36 | Own CI | Per PR: contract tier on 3 OSes at 1.13, full checked suite on ubuntu and macOS at 1.13. Weekly cron: everything, plus the DD-main and Julia pre/nightly canaries (allowed to fail). **Resolved (default):** the weekly cron also runs a `dd-floor` leg with DD pinned to `=0.4.29`. The GPU tier is run by hand on the L40S host, with `test/gpu` sourced from the checkout. | default | S5 |
| D37 | Release sequencing | Merged into D27. | owner (O15) | S5 (S6b) |
| D38 | Licensing | Keep MIT. Apache-2.0 attribution for the DD-derived template: SPDX header, `LICENSES/Apache-2.0.txt`, `THIRD_PARTY_NOTICE.md`. AI disclosure is optional. | default (O0) | S5 |
| D39 | Out-of-tree runner | No public API: a README recipe plus an internal injector tool (unexported, not covered by semver). | default | S5 |
| D40 | Matrix gating | The documented gate is `if !isempty(get(ENV, "DISPATCH_CHECKUP", "")) … end`, plus a separate checkup CI job with `DISPATCH_CHECKUP: "on"` (quoted). The unconditional two lines stay supported. | default | S4 |
| D41 | (number unused) | The import-closure proposal is a straightforward fix: extensions triggered only by DC's own closure are reported as "loaded by DispatchCheckup". | default | S5 |
| D42 | AD transparency | AD-transparent checker in 0.2.0: a collapsed prologue routed through DD's `_show_warning` AD-inactive rules. No AD weak deps. | default (O4) | S3 |
| D43 | Type-valued keywords | DD's check runs first; on failure, a singleton `Type{T}` retry decides. Each leniency is recorded. No keyword. | default (O4) | S3 |
| D44 | Method-table audit | Shipped in 0.2.0 as the coverage backstop. The audit has authority over coverage status; the walker supplies reasons and spans. | default | S3 |
| D45 | Config transport | Compile-time options (unstable selectors, `union_limit`, codegen level, matching-rules/schema version) go in one canonical preference table in the per-run environment's `LocalPreferences`. `mode`, `report`, `require_all` and `original` are runtime-only. | default | S2 |
| D46 | Image runtime hooks | One private submodule per image, which does the `pkgorigins` rewrite, the canaries, the record sink and the include observer. A build worker for the target or an extension runs the gate, the self-test and the walk, and refuses unless the private depot is `DEPOT_PATH[1]`, so a build of the target or an extension after activation fails loud (**Resolved (default)**: a documented divergence, §7 item 2). A worker building a dependent only rewrites `pkgorigins` and records the D45 preference; such builds are allowed after activation and reported as `lazy`. Live processes run the full hook. | default | S2 |
| D47 | Persistent state | The private depot location, key and `key.toml` are as in §4. All persistent writes are atomic. The open point on mirroring is shared with D17. | default | S2 |
| D48 | Known-instability waivers | Rejected as proposed: there is no runtime acceptance list. A known instability is accepted only by listing its definition in `unstable=`, which leaves it unwrapped. D48's site entry `:foo => "src/file.jl:LINE"` becomes `unstable=` form (d). | owner (O6) | S4 |
| D49 | Target cardinality | One target per run. A call naming a different target errors before any state change, also in descendants. Internals are keyed by target UUID. The v1 report has a single target. | default | S2 (S4) |
| D50 | Guard child contract | A `Pkg.test`-like `-e` runner. Files are included into `Main` in order, each inside a testset, and the runner continues past a failure. The phase is skipped on signals. `PDEATHSIG` on Linux. | default | S2 D18 (S4) |
| D51 | As-if-absent scope | Runtime equivalence plus an additive-only resolution delta, published as a compat table and asserted by the twin test, including history independence. It applies to Julia 1.13+. | default (O14) | S4 (S5) |
| SF | 37 straightforward fixes | All adopted and scheduled into P1–P3 and M (S5). Under D13: #56, #57/#63/#29 and #104 are moot (#104 is asserted by C-11). Under D30/D22: #119 and #31 are subsumed, and #35 now covers only the guard child. Under O4: #13 and #75/#120 become template properties, and the template partly absorbs #2 and #18. #99–#102 stay latent (1.14). | default | S5 |

### 5.3 Conflict resolutions (`decisions.json` `.conflicts`)

| # | Decisions | Resolution | Status |
|---|---|---|---|
| C0 | D04 D13 D17 D47 | Key overlays by (UUID, crc32c(realpath root)) under a per-Julia-minor root. Config stays out of the shim and the path. Pidlock with atomic writes. | Applies; the owner key adds name and layout version. No pidlock: DC's own writes are idempotent or write-once, so it takes no lock (S2 D17+D47; O14 adds no FileWatching). |
| C1 | D17 D47 D24 | Mirror only `scratchspaces` and `logs`. | Superseded by D17 (no mirroring; user depot first at runtime). The `dev/`/`packages/` question remains (open point 1). |
| C2 | D13 D46 D04 | The minimal overlay is a `Project.toml` copy plus the shims, with a copy-tree fallback. | Applies without the fallback (owner D13: no tree copy). |
| C3 | D05 D16 D46 | One private submodule per image. | Applies. |
| C4 | D03 D29 D45 | Mode is runtime-only and not in the image key. | Applies. |
| C5 | D03 D21 | Never throw in a pure context; record with context `generator`. | Applies. |
| C6 | D07 D09 | Block options propagate to each generated wrapper; `@unstable` is transparent-excluded. | Applies. Options feed the template, not DD's `@stable`. |
| C7 | D10 D11 D03 D48 | `waive=` matches instabilities, and the grammar is shared. | Superseded by O6. The grammar belongs to `unstable=` alone. |
| C8 | D03 D20 D22 | Test is looked up through `Base.loaded_modules`, not declared as a dependency. The recorder never logs or does IO; in pure contexts and finalizers it skips the testset lookup. | Applies. |
| C9 | D03 D23 | The recorder call sits where DD's throw was, behind a `@noinline` host function. | Applies, as a template parameter. |
| C10 | D02 D30 D50 | Skip guards when the exit code is ≥ 128. | Applies. |
| C11 | D12 D30 | Write-through records with a complete marker; the merge accepts partial files. | Applies. |
| C12 | D04 D22 D12 | Eager precompile at activation; capture the output. | Applies. The build set is D17's, as settled in S2 D04 (open point 2). |
| C13 | D08 D04 | Never wrap top-level load-time lambdas or do-blocks. | Applies. |
| C14 | D04 D05 D26 | Load-time detections are lost under images. Accept this as parity with native DD; the corpus measures it. | Applies. |
| C15 | D26 D51 D20 | The twin test asserts the D51 list. | Applies. Identical caches for the target and its dependents are achievable (D51). |
| C16 | D31 D19 D47 D18 | Reserve the prefix; document `DISPATCH_CHECKUP_DEPOT` and `…_ALLOW_UNTESTED_JULIA`; scrub all DC variables in the guard child. | Partly. The prefix and `DISPATCH_CHECKUP_DEPOT` apply. No window override is shipped (O14). The scrub applies: S2 D18 and S4 D31 scrub every `DISPATCH_CHECKUP*` name and add the `guard:<pid>` marker, against D50's "keep the user's value" (Resolved (default), §7 item 4). |
| C17 | D24 D45 D09 | Injected target preferences = DD mode + codegen level + DC table. | Superseded by O4. The injected preferences are the copied user view plus the DC table; DC writes no DD key, `dispatch_doctor_mode` included (S2 D24, S3.1). Open point 5 records the remaining S3 choices. |
| C18 | D29 D31 D12 D45 | A descendant whose compile-time options differ from the run config errors; runtime-only differences are noted and ignored. | Applies. |
| C19 | D16 D22 D30 | The verdict comes from in-process memory, plus a placeholder at activation. | Applies (`incomplete` placeholder). |
| C20 | D10 D33 | Widening bare `:foo` is a CHANGELOG item; multi-module matches are noted. | Applies (O6). |
| C21 | D13 D46 D05 | One include rule, decided by destination module and phase. | Applies. |
| C22 | D20 D47 D16 | Use `Base._crc32c` and `Base.UUID(rand(UInt128))`. | Applies. |
| C23 | D21 D03 D08 D43 | Keep DD's public `@stable` plus guarded rewrites as a release gate. | Superseded by O4. |

---

## 6 What changes from 0.1 (user summary)

- **Install.** Keep the URL `[sources]` entry with `rev = "main"`, and change `[compat] DispatchCheckup` from `"0.1.2"` to `"0.2"`. Until a repository makes that change, its resolution fails loudly after the merge. Julia 1.13 only, as before.
- **The two lines.** The activation call has the same shape. Comment out both lines to turn checking off; 0.1 said to comment out only the activation line. `import DispatchCheckup` now loads DD. For CI matrices, wrap both lines in the `DISPATCH_CHECKUP` gate and add a checkup job with `DISPATCH_CHECKUP: "on"`.
- **No relaunch.** The run is checked in place. `runtests.jl` is no longer re-run from the top, so setup code before the activation line runs once. The call must still come before `using MyPackage`.
- **Guards.** `test_original(...) || include(f)` is gone.
  - List the files in `original = ("test_guards.jl",)`.
  - Skip them with `get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("test_guards.jl")`.
  - Guard files now run standalone, after the suite, in a fresh process. Add `using Test, MyPackage` at their top.
  - Group-selector and no-argument forms become explicit file lists (S4 "Migrating from 0.1").
- **`source_root` is gone.** Use `pkgdir(MyPackage)`, which now reports the original checkout during checked runs. JET, ExplicitImports and similar tools see the original sources.
- **Default behaviour.** An unstable call no longer throws. Its real body runs, the instability is recorded, and the run fails at the end with the full list. Use `mode=:error` to get 0.1's throw-at-the-call behaviour.
- **`unstable=`.** Listed definitions are still not wrapped and not checked, but matching is wider.
  - A bare `:foo` now matches every definition named `foo` in the root module, its submodules and its extensions. In 0.1 it matched only `MyPackage.foo`.
  - New forms: `Symbol("MyPackageSomeExt.foo")`, foreign callees such as `Symbol("Base.getindex")`, and per-definition `:foo => "src/file.jl:LINE"`.
  - An entry for unloaded code is reported as inactive instead of failing the run.
- **New and changed keywords.**
  - New: `original=`, `union_limit=` (default 1, applied to DC's wrappers) and `mode=`.
  - `report=` now writes a default file in the private depot when omitted; `report=false` disables it. A relative path resolves against the activating file, not cwd.
  - `require_all=true` now fails only on unacknowledged blind spots.
  - `entrypoint=` is gone (it is now a `MethodError`).
- **Report.** TOML with `schema_version = 1`. It says `incomplete` until the run finishes, lists every instability with its signature and sites, and lists by-design skips, limitations, blind spots and unloaded extensions.
- **Wider coverage.**
  - Distributed workers and `run(julia ...)` subprocesses now load the instrumented target and report into the run.
  - Zygote gradients through checked functions keep production inference and speed (D42).
  - DD's expansion warnings no longer appear in test output.
- **JLL packages.** They load and run as before, but inference is no longer switched on in modules that disable it. Those modules are reported as by-design skips (O10).
- **Caches.** Instrumented images persist in `~/.julia/compiled/v1.13/.dispatchcheckup/`, which `julia-actions/cache` saves. `DISPATCH_CHECKUP_DEPOT` relocates them. Repeat runs reuse them instead of rebuilding. A dependent that is first compiled after activation is cached in the user depot under its own slug, never over a production file, and is reported as `lazy`.
- **New refusals.**
  - Interactive sessions (REPL, Pluto, VS Code notebooks, IJulia).
  - A second, different target in the same process.
  - Distributed workers started before activation.
  - Any `DISPATCH_CHECKUP` value other than unset, `""` or `"on"`. Unknown `DISPATCH_CHECKUP_*` variables are not refused: DC ignores them and lists them in the banner.
  - An operating system other than Linux, macOS or Windows.
  - Building the target or one of its extensions after activation, for example for an extension triggered late or an environment created by the tests.
- **Dependencies.** DC no longer depends on Pkg, SHA or UUIDs, and its compat no longer raises users' MacroTools or Preferences versions. Instead, activation fails closed below DD 0.4.29 or MacroTools 0.5.12.

---

## 7 Open points carried to other sections

Items marked **Settled** or **Resolved (default)** are closed. Item 1 waits on the P1.0 prototype, and item 8 is a standing note. Items 12 and 13 are the only points still open for the owner.

1. **Depot mirroring (S2, S5 P1).** D47 measured cache rejection on every run for a target in `~/.julia/dev` when `dev/` is not mirrored (`$AUDIT/D47-persistent-state-cbe97c0c/exp1.sh`). D17 loaded images with no mirroring (`$AUDIT/challenge-D17-depot-layout-r8k3/exp`). S2 D17+D47 adopts the sibling layout (`O` beside `P` in the key directory, no mirrors) provisionally. The P1.0 prototype (S5) must confirm it before the layout is committed. If mirrors come back, the Windows data-safety subset of D25 (junctions) also comes back.
2. **Up-front build set and builds after activation (S2). Settled; builds after activation Resolved (default).** D17 builds the target, every dependent in the active manifest and every buildable extension; C12 built only what already has a production cache. In the D17 challenge's toy run, which carried no D45 preference, a dependent compiled lazily against the overlay overwrote the user-depot production cache with the same slug (`$AUDIT/challenge-D17-depot-layout-r8k3/exp/checked_alt2.jl`). S2 D04 uses D17's set and keeps C12's output capture. After activation:
   - the D46 gate refuses to build an instrumented image of the target or of one of its extensions, and fails loud. This is a documented divergence: for example, an extension triggered late or an environment created by the tests cannot load the target in a checked run;
   - lazy builds of dependents are allowed. They land in the user depot under a distinct cache slug, because they carry the D45 preference, never overwrite a production file in place, and are reported as `lazy`. The S5 contract C-12 therefore requires zero files in the user depot for the target and its extensions, not for dependents.
3. **Activation reached inside the guard child (S2, S4). Resolved (default).** The decisions disagreed: D02 used a marker `DISPATCH_CHECKUP_RUN=original:<pid>` and made activation an error; D16 and D29 made it a no-op; D50 used no DC variables at all. S4 (state machine step 2) and S2 D18 use the marker `DISPATCH_CHECKUP_RUN=guard:<pid>`, and activation reached inside the guard child or any of its descendants is **inert**: it returns `nothing` and starts no nested run, so the guard keeps running against the original code (S4 open point 4).
4. **Guard-child `ENV` (S2, S4). Resolved (default).** D50 kept the user's `DISPATCH_CHECKUP` value; C16 scrubs every `DISPATCH_CHECKUP*` name. S2 D18 and S4 D31 follow C16: the guard child's `ENV` is the pre-activation snapshot minus every `DISPATCH_CHECKUP*` name, plus the item 3 marker `DISPATCH_CHECKUP_RUN=guard:<pid>`, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored to their pre-activation values.
5. **DD preference forcing under O4 (S3). Settled.** `checking_enabled()` is a runtime check, and the template fixes mode and codegen, so DC wrappers need no DD preference.
   - DC writes no DD preference key, `dispatch_doctor_mode` included (S2 D24, S3.1). Source `@stable` that DC cannot re-wrap (inside a `quote`, a non-literal `@eval`, an opaque macro or a function body) expands natively under the production preferences and is reported by the D44 audit as `checked` with origin `native` (S3.3).
   - "Honour their union limit" includes the user's `dispatch_doctor_union_limit` preference for source annotations, as in production (S3.3). It does not change DC-generated wrappers, which follow `union_limit=` (S4 open point 2).
6. **Shim-to-DC call form (S2). Settled.** In the critic's experiment, a shim that defines a closure failed to precompile, so the mapper code must live in DC (`$AUDIT/critic-completeness-q7r3`). S2 D13 calls DC's mapper from the shim with two plain top-level statements and no `invokelatest`, so O1's "no invokelatest bridges" holds literally.
7. **MacroTools floor (S4, S5). Resolved (default).** With MacroTools below 0.5.12, the walker silently reported 22 sites as unsupported (`$AUDIT/D20-dependency-footprint-m3q8`). O14 sets compat `"0.5"` and names only the DD activation check. S4 (step 5) and S5 D20 add a fail-closed activation check that `pkgversion(MacroTools) >= 0.5.12`, in addition to `pkgversion(DD) >= 0.4.29` (S5 open point 6). The floor is re-measured after the walker refactor (D01 P2).
8. **Window override (S5).** No variable is shipped. The weekly pre/nightly canary patches DC's window constant and its `JULIA_OK` check in a scratch copy (S5 D36; D19).
9. **Reserved prefix versus consumer convention (S4, S6b). Resolved (default).** Every consumer call passes its report path from a consumer-defined variable under the reserved `DISPATCH_CHECKUP_` prefix (`$AUDIT (consumer inventory)`). S4 D31 makes DC ignore unknown `DISPATCH_CHECKUP_*` names and list them in the banner; consumers may keep reading their own variables in test code. One consumer probes the `DispatchCheckup` module with `isdefined` for `source_root`, which violates A2; it switches to `pkgdir` (the private consumer migration plan, S6b).
10. **Owner items. Settled.** O0, O1, O4, O6, O10, O14 and O15 are the only owner items for 0.2.
11. **`require_all` scope (S4 open point 8). Resolved (default).** The spec reads O6's "code that could not be checked" through D11: only blind spots that are not listed in `unstable=` are counted. DD limitations are reported with locations and counts, and are never counted.
12. **Consumer rollout path and `v0.1.2` pin fallback (S5 open point 12). Open for the owner.** The owner must choose the rollout path for the open consumer integration PRs, and decide whether a consumer that cannot migrate on merge day may temporarily pin `rev = "v0.1.2"` as a fallback, a deviation from O0's `rev = "main"`.
13. **Effort estimate (S5 open point 8). Open for the owner.** S5's bottom-up estimate is 45–63 developer-days; D01's 17–25 covers only the core code. The owner must accept the estimate or name scope cuts.

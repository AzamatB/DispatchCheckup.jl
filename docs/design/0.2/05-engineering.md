# S5 Engineering plan

This section covers how DispatchCheckup (DC) 0.2 is built, tested, released and scheduled: dependencies, Julia window, platforms, CI, tests, branching, licensing, audits, the phase plan and the risk register. Conventions follow S1: "must", "should" and "may" are normative; `O*` owner items override everything (the only owner items are O0, O1, O4, O6, O10, O14 and O15; settled); `SF #N` is the straightforward fix for finding `#N`; `C0`–`C23` are the conflict resolutions, numbered by their 0-based index in `decisions.json` `.conflicts` (S1 §5.3); `$AUDIT` is the maintainer's local review archive (not part of this repository), as defined in S1's conventions. "Resolved (default)" marks a point settled by the lead reviewer's recommendation, which the owner accepted for every item the owner did not decide.

---

## D20 Dependency closure and compat

**Decision.** DC declares only what DispatchDoctor (DD) already loads. Compat ranges equal DD's own (O14). Tested floors that compat cannot express without perturbing users are enforced at activation and fail closed.

**Requirements**

- In `Project.toml` for 0.2.0, `[deps]` and the `[compat]` entries for julia and the deps must be exactly as below. Each `[extras]` package keeps its own `[compat]` entry, as 0.1.2 already does, because `Aqua.test_all(DispatchCheckup)`'s `deps_compat` check covers extras:

  ```toml
  [deps]
  DispatchDoctor = "8d63f2c5-f18a-4cf2-ba9d-b3f60fc568c8"
  MacroTools     = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
  Preferences    = "21216c6a-2e73-6563-6e65-726566657250"   # its public API is used (D45 load_preference)
  TOML           = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

  [compat]
  julia = "1.13"
  DispatchDoctor = "0.4"
  MacroTools = "0.5"
  Preferences = "1"
  TOML = "1"
  ```

- **Preferences.** It is in `[deps]` because DC calls its public API: S2 D45 reads the compile-time table with `Preferences.load_preference` in build workers and in the hook `__init__` of dependent builds. That satisfies O14's condition. If a later design stops calling it, it must leave `[deps]` (O14), and the reads must use `Base.get_preferences` with `Base.record_compiletime_preference` behind the compat module. Either way it stays in DC's load closure through DD.
- **Removals.** `Pkg`, `SHA` and `UUIDs` leave `[deps]`. They move to `[extras]` only where DC's own tests still use them (`test_support.jl` uses Pkg and SHA; fixtures use `uuid4`).
- **Forbidden in DC's `Project.toml`:**
  - `[weakdeps]` and `[extensions]`. A weakdep's compat binds every user who has that package.
  - A `[sources]` entry for any `[deps]` package. Pkg propagates `[sources]` of a url- or path-tracked dependency's `[deps]`. `[sources]` for `[extras]` (the Aqua and CheckConcreteStructs forks) does not leak. Resolved (default): the current fork pins stay in `[extras]` as they are; switching to registered versions is out of scope for 0.2 (open point 5).
- **Activation-time floors.** These must run before any side effect and fail closed. Each error must name the installed version and the remedy; the wording is S4's (state machine "Messages"):
  - `pkgversion(DispatchDoctor) >= v"0.4.29"` (O14);
  - `pkgversion(MacroTools) >= v"0.5.12"` (Resolved (default): adopted in addition to the DD floor; S1 open point 7, S4 compat table, open point 6 below);
  - the DD runtime-helper self-test (O4), and `DispatchDoctor.JULIA_OK` true.
- **Closure targets.** Activation must refuse a target that is in DC's load closure: DispatchCheckup, DispatchDoctor, MacroTools, Preferences, TOML, Dates, Printf (SF #40).
- **Replacements.**
  - `Base.UUID` for `UUIDs.UUID`.
  - `Base.uuid5` for extension PkgIds. `UUIDs.uuid5` gives different values.
  - `Base._crc32c` for keys, behind the compat module.
  - `Base.pkgversion` for version gates. Delete `_validate_tool_compatibility` and the use of `Pkg.Types.semver_spec`.
  - `Base.Precompilation.precompilepkgs` for the up-front build, behind the compat module with a shape assertion and a `Base.compilecache` fallback.
  - `TOML.parsefile` and `TOML.print`. Results of `Base.parsed_toml` must never be mutated, because they are shared with the loader cache.
- **Top-level code** must not reference DD or Base internals, except S3.1 R8's `isdefined`-guarded `_show_warning(::Site, …)` method and its window-gated, `try`/`catch`-wrapped template precompile workload (S1 A4). Every other internal access goes through compat-module functions called after the window check, so DC precompiles on every Julia that compat admits.

**Rationale**

- The status quo adds 25 modules after `using Test` (warm import 0.746 s). The minimal set adds 7 (0.137 s) (`$AUDIT/D20-dependency-footprint-m3q8/scripts/loadquo.jl`).
- In a real `Pkg.test`, compat narrower than DD's silently upgraded a locked MacroTools 0.5.13 to 0.5.16 and a locked DD 0.4.25 to 0.4.29. DD-equal compat changed nothing (`runs/pkgtest`, `runs/pkgtest-dd`).
- Below MacroTools 0.5.12 the walker silently reports 22 sites as unsupported, so that floor must be checked at activation. The floor was measured on the frozen 0.1 walker; it must be re-measured after the walker refactor (P2 exit) and the activation check updated if the result moves.

**Tests**

- **C-07 static table, per PR.** The `[deps]` set and the compat entries for julia and the deps equal the block above, and every `[extras]` package has a compat entry. No weakdeps or extensions. No `[sources]` on deps.
- **C-06 import closure.** In a fresh process, `using Test; import DispatchCheckup` adds exactly Dates, DispatchCheckup, DispatchDoctor, MacroTools, Preferences, Printf and TOML. It writes no files, does not change `ENV`, `LOAD_PATH` or `DEPOT_PATH`, and registers no task or `atexit` hook.
- **C-04 additive resolution** (D51 twin, below).
- **F-02 floors.** Fixtures lock DD 0.4.25 and MacroTools 0.5.11. With the lines commented out, the locked versions do not move. Activated, the run errors and names the version.
- **Weekly headroom.** The latest registered DD, MacroTools, Preferences, EnzymeCore and ChainRulesCore must fall inside the effective compat. A failure opens an issue.

---

## O14 Julia window (replaces D19)

**Decision.** Compat is `julia = "1.13"`, that is [1.13, 2.0). The validated runtime window is 1.13.x. There is no stub module and no version-gated `include`: every Julia runs the same source. Activation outside the window errors clearly.

**Requirements**

- **As-if-absent from 1.13 on.** DC must precompile and import with no `ERROR` or `WARNING` on every Julia that compat admits, including 1.14 and later once released. Top-level code therefore must not touch DD internals or version-specific Base internals, apart from S3.1 R8's guarded method and its window-gated, `try`/`catch`-wrapped template workload (S1 A4).
- **Wrapper precompile workload.** It exists to remove about 4 s of first-use JIT (D21). It must run only when the window predicate holds at precompile time.
- `public dispatch_doctor` is written directly. It parses on 1.13.
- **Activation order.** The window check runs at S4 state-machine step 5, before any side effect (only pure argument validation, the guard-marker check, the interactive refusal and the generating-output check precede it). Its first test is `v"1.13.0" <= VERSION < v"1.14.0-"`. Otherwise activation throws an error that names `VERSION`, the window and the remedy: run checked jobs on 1.13 and gate the lines (D40). Prereleases of 1.13 are outside the window. The second check is that DD's `JULIA_OK` is true.
- **No override.** Neither a user nor a maintainer override ships. The `DISPATCH_CHECKUP_ALLOW_UNTESTED_JULIA` idea in C16 is not adopted. The weekly forward-port canary patches the window constant in a scratch copy instead.
- **Widening to 1.14** requires all of:
  - 1.14 is released;
  - fixes for #99–#102 have landed;
  - the forward-port canary is green;
  - a decision on the `JULIA_OK` check, because DD 0.4.29 reports false on ≥1.14-DEV.

**Rationale**

- DD 0.4.29 precompiles and loads on 1.14.0-DEV.3787 and 1.15.0-DEV.16 with `JULIA_OK=false`.
- The eager 0.1 implementation precompiled cleanly on 1.10 through 1.15-DEV (`$AUDIT/D19-julia-window-k7q2`, DCeager). A stub is not needed for precompile health.

**Tests**

- **Unit test of the window predicate** over a version table that includes 1.13.0-rc1, 1.13.0, 1.13.9, 1.14.0-DEV and 1.14.0.
- **F-01, weekly `pre`/`nightly`.** Precompile and import are clean. Activation errors before any side effect: no files under the private root, and `ENV` unchanged.
- **Per PR.** `setup-julia` version `'1.13'` tracks the newest 1.13 patch automatically.

---

## D25 Platform tiers

**Decision.** There are two tiers, as with Julia versions.

- **Tier 0, dependency contract.** On Linux, macOS and Windows: resolve, precompile, import, and the closed gate.
- **Tier 1, checked runs.** Supported on Linux and macOS. Experimental on Windows. Any other OS fails closed at activation (Resolved (default), open point 11).

**Requirements**

- **Tier 0 is required per PR** on `ubuntu-latest`, `macos-latest` (arm64) and `windows-latest`, all at Julia 1.13 (D36 `contract`).
- **Tier 1 on Linux and macOS.** The full suite is required per PR.
- **Path identity.** One helper canonicalizes every root once with `realpath(abspath(...))` at creation (SF #52).
  - Every identity, mapper, `original=` and leak comparison compares realpaths of existing files.
  - A path that cannot be canonicalized fails the run closed.
  - On case-insensitive volumes (macOS default, Windows), comparisons should fold case. The macOS leg verifies this.
- **Exported path lists** (`JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH`; D12, D18) use Base's separator: `;` on Windows, `:` elsewhere.
- **No links.** DC must create no symlinks, hardlinks or junctions. D13's minimal overlay needs none. A grep test fails if `src/` calls `symlink`, `hardlink` or `ln` outside an approved helper.
  - If the P1.0 prototype forces depot mirroring, D25's link rules return: one helper, absolute paths to existing directories only (a junction on Windows), never file links. The Windows data-safety subset (junction `islink`, `rm` and `Pkg.gc` leave the user depot intact) then becomes required before Windows activation is allowed.
- **Windows activation** prints one warning line and writes `platform_tier = "experimental"` into the report.
- **Linux path variants.** The Linux full job re-runs the path-identity subset with a symlinked `TMPDIR` and a symlinked depot. This stands in for macOS `/var` → `/private/var`.

**Rationale**

- Under Design A, DC is a declared test dependency. Every downstream matrix leg precompiles it, Windows included, so Tier 0 is mandatory whatever is decided about checked runs.
- D13 removes the per-file symlinks that broke Windows (#32).
- Hosted runners are free for this public repository, macOS included (`gh repo view`: PUBLIC; `$AUDIT/D25-platform-support-p7w3`).

**Tests**

- C-01, C-03, C-06 and C-07 on all three operating systems.
- The full suite on Linux and macOS.
- Weekly Windows full suite (D36). Known gaps are marked `@test_broken`, and the list may only shrink.
- The path-variant subset.
- The no-links grep test.

---

## D36 CI matrix and workflows

**Decision.** Two workflows and one manual tier.

- `ci.yml` runs per PR and on pushes to `main` and `redesign-0.2`. It is also callable.
- `weekly.yml` runs on a cron schedule and by `workflow_dispatch`, and calls `ci.yml` plus the canaries.
- The GPU tier is a maintainer script on the L40S host.
- The current `.github/workflows/test.yml` (one ubuntu job, `JULIA_PKG_PRECOMPILE_AUTO=0`) is replaced.

**`ci.yml` (required checks)**

| job | runners | Julia | content | budget |
|---|---|---|---|---|
| `hygiene` | ubuntu | 1.13 | static tests: Project table (C-07), grep invariants (no links, no top-level internals apart from S3.1 R8's guarded method, no `@__DIR__`-derived runtime paths, SPDX header and notice), `FINDINGS.toml` coverage | 2 min |
| `contract` | ubuntu, macOS, Windows | 1.13 | `test/contract`: resolve, twin (C-01, C-04, C-05), `Pkg.precompile(strict=true)` with no ERROR/WARNING, import closure (C-06), gate unset and `""` (C-03). Gate `"on"` and C-02 history run on ubuntu and macOS only. Autoprecompile must be **on**. | 3–5 min |
| `full` × group ∈ {unit, integration, regression, guards} | ubuntu, macOS | 1.13 | the full checked suite, split into groups that run in parallel; ubuntu adds the path variants | ≤ 10 min wall |
| `recipe` | ubuntu | 1.13 | the documented D40 checkup job, run verbatim against the Target fixture (`julia-actions/julia-runtest`, step-level `DISPATCH_CHECKUP: "on"`, `coverage: false`), plus one step with coverage on (images still load under `--code-coverage`) | 5 min |

- All jobs must use `setup-julia` with `'1.13'` and `julia-actions/cache`.
- PR concurrency groups cancel superseded runs.
- Branch protection on `main` and `redesign-0.2` requires every job above.

**`weekly.yml`** (cron `0 4 * * 1`). Canary and corpus failures must open or update one issue per job (label `canary`, `issues: write`) and must not affect required checks.

| job | content | may fail |
|---|---|---|
| `all` | calls `ci.yml`. A fresh resolve picks the newest DD, MacroTools and Preferences in range; `Manifest*.toml` is gitignored. | no (issue) |
| `windows-full` | full suite on `windows-latest`, with the `@test_broken` list | yes |
| `dd-main` | DD from GitHub `main`: full suite (ubuntu), the helper self-test, and a hash of DD's `_stabilize_fnc` source compared with the recorded hash. A hash change asks for a porting review; it is informational only. | yes |
| `dd-floor` | DD pinned to `=0.4.29`. Resolved (default): this weekly leg is adopted, because the range floor is otherwise never tested once 0.4.30 exists (open point 7) | no (issue) |
| `julia-pre`, `julia-nightly` | (a) contract subset: precompile and import clean, activation errors (F-01); (b) forward-port: full suite with the window constant and the `JULIA_OK` check patched in a scratch copy, to surface #99–#102 early | yes |
| `twin-latest` | twin fixtures with the newest EnzymeCore and ChainRulesCore, plus the D20 headroom check | no (issue) |
| `ad` | Zygote contract test (D42, #111) | no (issue) |
| `corpus` | D26 real-package corpus through the internal injector (D39), sharded one package per job, 60 min each | yes |

**GPU tier (manual)**

- `test/gpu/Project.toml` must source DC by path: `[sources] DispatchCheckup = {path = "../.."}`, compat `"0.2"`, `julia = "1.13"`.
- `test/gpu/run.sh` instantiates that environment and asserts that `pathof(DispatchCheckup)` lies inside the checkout (SF #43). It then runs `test_gpu.jl` with `CUDA_VISIBLE_DEVICES` set.
- The maintainer also runs GodelaAMGX_jll's checked suite on the same host (S6a).
- A passing log is required before tagging v0.2.0 and on every PR labelled `gpu`.
- No self-hosted runner is attached to this public repository.

**Not built:** TagBot, CompatHelper, Registrator (O0, O15).

**Rationale**

- The repository is public, so hosted macOS and Windows minutes are free. No GPU runner exists (runner API `total_count: 0`) (`$AUDIT/devil-D36-own-ci-matrix-q8z3`).
- Today's single job takes 9m11s: integration 6m11s, and launcher tests 2m03s that go away (`$AUDIT/testsuite-review-q7k2/ci_log.txt`).
- DD's `JULIA_OK` is a precompile-time constant, so a nightly canary that patches nothing only ever shows a vacuous fail-closed red.

**Tests.** The workflows are their own test. `hygiene` additionally asserts that `ci.yml` lists the three contract operating systems and that the GPU `Project.toml` uses a path source.

---

## D26 Test strategy

**Decision.** Triage the 0.1 suite rather than keep it as the specification. Write the contract and fail-closed tests first, then turn the review repros into a regression corpus with one entry per finding. Real packages run weekly.

### Layout

| path | content | runs |
|---|---|---|
| `test/runtests.jl` | group selection through `ARGS` (`unit`, `integration`, `regression`, `guards`); every group is selectable (fixes #68) | per PR |
| `test/unit/` | walker cases (from `test_instrumentation.jl`), wrapper template, compat-module smoke test per internal symbol (SF #80), keyword normalization, path identity | per PR |
| `test/contract/` | its own stdlib-only project; twin harness, fixture generator, hygiene, gate, fail-closed | per PR, 3 OS |
| `test/integration/` | `Pkg.test`-based fixture scenarios (rewritten `test_integration.jl`) | per PR |
| `test/guards/` | D02/D50 guard-child contract | per PR |
| `test/regression/walker/` | in-process differential cases: evaluate original and instrumented source in one session, run the same body on both, compare outcomes and the exact versioned report records | per PR |
| `test/regression/loading/` | a few multi-case fixture packages, with one `Pkg.test` per mode | per PR |
| `test/regression/FINDINGS.toml` | finding → {group, test id, status = test, moot, docs or canary}; `hygiene` asserts that every listed test id exists | per PR |
| `test/corpus/` | injector (D39), `packages.toml` with pinned versions, runner | weekly |
| `test/gpu/` | manual tier | manual |

- Test-only switches must use the `DCTEST_` prefix, never the reserved `DISPATCH_CHECKUP_`.
- Regression testsets are named `F#<n> …`. Contract tests are named `C-nn` or `F-nn`.

### Contract and fail-closed tests first

These are written before the shell is rebuilt (P1.1). C-04, C-06 and C-07 fail against 0.1.2 today, because of the compat floors (MacroTools 0.5.16, Preferences 1.6.1, DD 0.4.29) and the Pkg/SHA/UUIDs closure. They turn green with the D20 changes. The F tests land with the feature they guard.

| id | asserts |
|---|---|
| C-01 | **Twin**: lines commented out vs DC removed, in both `[extras]/[targets]` and `test/Project.toml` layouts (D51 list below) |
| C-02 | **History**: U1 → checked → U2 give identical observables. The checked run leaves the package tree, the test Project, Manifest and LocalPreferences, and user-depot `compiled/v1.13/<Target>` byte-identical |
| C-03 | **Gate** (D40): `DISPATCH_CHECKUP` unset and `""` equal C-01's commented-out observables; `"on"` activates |
| C-04 | **Additive resolution**: fixtures with older locked MacroTools and Preferences, and a DD-native package with DD 0.4.25 locked. No version moves, no "re-resolving" line |
| C-05 | **Aqua**: `Aqua.test_all` with the Quick-start snippet, including `[compat] DispatchCheckup = "0.2"`, passes with the lines commented out (#49) |
| C-06 | import closure and import side effects (D20) |
| C-07 | static Project table (D20) |
| C-10 | **Guards**: `original=` files run after the suite in one fresh process, against the original code. In that process `pathof` is the checkout, DC is not loaded (nor DD, unless the target itself depends on it), `DISPATCH_CHECKUP` is not `"checked"`, and no checked-run state is inherited. The guard child's `ENV` is the pre-activation snapshot minus every `DISPATCH_CHECKUP*` name, plus the marker `DISPATCH_CHECKUP_RUN=guard:<pid>`, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored to their pre-activation values. Activation reached inside the guard child or its descendants is inert: it returns `nothing` and starts no nested run (S4; Resolved (default)). Activation registers exactly two `atexit` hooks: the finalizer (validate, report, guards, exit status) and the D50 reaper, which only kills a guard child still alive after a signal (Resolved (default)). Files run in order, each in a testset, continuing after a failure. Final status is the first nonzero of (suite, validation, guards). The skip idiom works in the checked process |
| C-11 | **Identity**: `pathof`, `pkgdir`, `pkgversion`, `source_path`, `@__FILE__` and `@__DIR__` give the checkout at precompile time, in `__init__` (root, submodule, both extension layouts) and at run time. `locate_package` returns the shim. The overlay `Project.toml` is byte-identical. There is one hidden submodule per image |
| C-12 | **Images**: built eagerly in the private depot. Reused on run 2, and the report says reused. Zero files written to the user depot's `compiled/` entries for the target and its extensions. Building the target or an extension image after activation is refused loudly by the D46 gate (a documented divergence: a late-triggered extension or a test-created environment cannot load the target in a checked run). A dependent built lazily after activation is allowed: it lands in the user depot under a distinct cache slug (it carries the D45 preference), never overwrites a production file in place, and is reported as `lazy` (Resolved (default)). A config change rebuilds and reverting reuses. Concurrent runs of two configs and of two checkouts. `Pkg.gc()` survival. Targets in `~/.julia/dev` and `~/.julia/packages`. `DISPATCH_CHECKUP_DEPOT` |
| C-13 | Scratch and log writes land in the user depot; `DEPOT_PATH[1]` is the user depot while tests run |
| C-14 | **Environment**: the active project is unchanged (pinned). `LOAD_PATH` is the injected env followed by the original entries. Tests see `DISPATCH_CHECKUP == "checked"`. Descendants receive the D12 export, and the guard child does not |
| C-15 | **Report lifecycle**: `incomplete` placeholder written at activation; atomic final write; `report=nothing` prints the private-depot path; a relative `report="x.toml"` resolves against the activating file; `report=false` writes nothing |
| C-16 | **Keywords**: exactly the six O6 keywords (`Base.kwarg_decl`), all listed in the docstring. A lone Symbol or Pair counts as one item; any iterable is accepted. An unknown keyword is a `MethodError`; a malformed value is an `ArgumentError` naming the keyword |
| C-17 | **Modes**: `:record` runs real bodies and fails at the end with the full list; `:error` throws at the call; switching mode reuses the image |
| C-18 | `Pkg.test` (sandbox `JULIA_LOAD_PATH="@:<tmp>"`) and direct-script runs give the same results for C-10 to C-17 |
| F-01 | Julia outside the window errors before any side effect |
| F-02 | DD below 0.4.29, MacroTools below 0.5.12, a missing DD helper, or `JULIA_OK` false |
| F-03 | interactive session (piped `julia -i`, `Pkg.test` from `-i`) |
| F-04 | invalid `DISPATCH_CHECKUP` (including YAML-coerced `"true"`, with a hint); `"checked"` without a valid run marker. An unknown `DISPATCH_CHECKUP_*` name is not an error: DC ignores it and lists it in the banner (Resolved (default)) |
| F-05 | target already loaded; target in DC's closure |
| F-06 | a second, different target, in the same process or in a descendant; a repeat call with different options names the option |
| F-07 | an unmatched `unstable=` entry fails at load with nearest candidates; an inactive entry is reported and is not an error |
| F-08 | an `original=` file is missing, is the activating file, or is included in the checked process (D32) |
| F-09 | the report path is unwritable at activation |
| F-10 | the suite exits before loading the target: distinct status "target never loaded; nothing was checked" |
| F-11 | SIGINT or SIGTERM: report `interrupted`, guards skipped, nonzero status |
| F-12 | an instrumentation error in the precompile worker surfaces as a load error with its cause; no silent fallback to source loading (load-mode assertion) |
| F-13 | broken load identity: cache outside the private depot, hook not run, or `LOAD_PATH` reset by tests |
| F-14 | Distributed workers exist before activation |
| F-15 | inactive canary: inference or checks disabled process-wide |
| F-16 | an aliased `include`, `include_string` or `Core.include` bypass gives a load error or an audit finding |
| F-17 | an unsupported OS (anything other than Linux, macOS and Windows) fails closed at activation |

### Twin harness (D51)

- **Location.** `test/contract/twin.jl` generates a package, runs `Pkg.test` twice and compares observables. The observer code injected into `runtests.jl` must use Base only. Importing TOML there failed, because TOML is not in the test environment, and adding it would perturb what is measured (`$AUDIT/D26-test-strategy-m3k8`).
- **Environment.** Each run uses a private depot first and the shared depot read-only. `JULIA_LOAD_PATH` and `JULIA_PROJECT` are removed. Autoprecompile is on. DC is injected with `Pkg.develop(path=checkout)`.
- **Compared** (S4 D51):
  - loaded modules, with versions;
  - `pkgorigins`, including the target's and dependents' `cachepath`;
  - `ENV`, `LOAD_PATH`, `DEPOT_PATH`, the active project, `pwd`, `ARGS` and `PROGRAM_FILE`;
  - Test counts and the exit status;
  - output from "Testing Running tests..." on, with timings normalized;
  - the manifest: the without-DC manifest plus closure entries only.
- **Excluded:** Pkg's pre-test output, `OLDPWD` and wall time. The added closure entries are checked by the manifest rule above, not compared.
- **Cost.** It was deterministic, at 10 s without DC and 14–16 s with DC on a loaded host (`$AUDIT/D26-test-strategy-m3k8/twin.sh`). The weekly corpus reuses the same harness.

### Triage of the 0.1 suite

| file / testset | verdict | reason | phase |
|---|---|---|---|
| `runtests.jl` | rewrite | groups through `ARGS`; `TEST_FILES` omits `test_launcher.jl` (#68) | P1 |
| `test_aqua.jl` | rewrite | drop `_implementation()` and the `stale_deps` ignore list, which existed for the lazy dependencies; plain `Aqua.test_all(DispatchCheckup)` | P1 |
| `test_check_concrete_structs.jl` | rewrite | drop `_implementation()`; recurse from `DispatchCheckup` | P1 |
| `test_instrumentation.jl` `fixture` helper | rewrite | `const I = DispatchCheckup`. All 118 assertions passed with only this change on an eager module (`$AUDIT/D01-rewrite-strategy-q7x2`). Also: a typed config instead of the TOML file, and no snapshot or overlay roots | P1 |
| … "Source mapper preserves includes, locations, and identity" | keep (P1 oracle) | delete the snapshot assertions (rewrite of `plain.jl` after the snapshot, `!startswith(file, snapshot)`); counts become exact records | P1, P2.2 |
| … "Aliased includes fail coverage validation" | keep | F-16 | — |
| … "First-class include_string loaders fail closed" | keep | message updated by SF #55 | P2.8 |
| … "Bare exclusions select the root generic and all its methods" | rewrite | O6 grammar (a): `:foo` now also covers `Nested.foo`, and `:getindex` covers `Unrelated.getindex`. Per-generic counts become per-definition records. The unmatched case stays an error, now with nearest candidates | P2.6 |
| … "Native control macros and registered decorators remain supported" | rewrite | DC never reads DD's `register_macro!` table (D06), so `@passthrough` definitions become unwrapped blind spots, acknowledged through `unstable=`. Keep the `@static` and `@everywhere` parts | P2.3 |
| … "Unsupported definitions are visible" | rewrite | literal `@eval` bodies are instrumented (D11); `@generated` is a limitation; D11 classes | P2.2, P2.7 |
| … "Literal macros and empty generics do not create coverage gaps" | rewrite | an unknown string macro that defines no method is not a gap once the D44 audit lands | P3.3 |
| … "Wide argument lists retain precise checker signatures" | keep, move | becomes the template long-tuple test: 0 allocations at 40 arguments | P2.1 |
| … "Type-valued keyword arguments preserve singleton types" | keep, extend | D43 leniency record | P2.1 |
| … "Callable storage remains concrete through inner constructors" | keep | — | — |
| … "Type arguments keep inference checks out of the runtime path" | keep | 0-allocation invariant | — |
| … "Debug simulators preserve macro and method source locations" | keep, extend | add the #13 anonymous and operator command literals | P2.1 |
| … "Documentation retains recursive instrumentation and source provenance" | rewrite | delete the two `source_root` assertions (O15) | P1 |
| … "JLL loader metadata leaves inference enabled for checks" | rewrite | O10/S6a: inference must not be re-enabled, so `unstable(true) == 1` in both modes; by-design skip | P2.4 |
| … "Include declarations retain their signatures" | keep | adapt to the new context type | P1 |
| … "Included source cannot escape the snapshot" | delete | no snapshot (D13); replaced by C21 include-rule cases | P2.8 |
| `test_environment.jl` "environment snapshots preserve locked records…" | rewrite | becomes D24 derivation tests: record copied from the env Base resolves, versioned manifest, absolutized paths | P1 |
| … "source snapshots are writable copies and large assets are shared" | delete | `_copy_package_tree` and `_source_fingerprint` are gone (D13, D16) | P1 |
| … "package-root aliases keep source entries inside the canonical root" | rewrite | path-identity helper (#52) | P1 |
| … "manifest-free packages retain optional extension dependencies" | rewrite | D24 record: weakdeps and extensions kept, trigger entries listed | P1 |
| … "strict target preferences leave originals and unrelated preferences intact" | delete | O4 ends DD preference forcing (#19). Replaced by a D45 test: canonical table, unrelated preferences intact, original file untouched | P1 (new), P2.1 (delete) |
| `test_integration.jl` `check_cleaned_overlay` | delete | asserts that `pkgdir` differs from the checkout and that the temp project was deleted, which contradicts D13, D24 and D17 | P1 |
| … "JLLWrappers platform includes stay instrumented" | rewrite | O10/S6a | P2.4 |
| … "commented activation is ordinary Pkg.test" | rewrite | becomes C-01 and C-03. Comment out **both** lines; use a private depot (#66) | P1 |
| … "actual Pkg.test instruments every supported source path" | rewrite | drop `DCT_ENTRY_FLAGS` length 2 (relaunch); keep `repeat=true` as the idempotence check; assert records or use `mode=:error` | P1 |
| … "qualified exclusions do not disable adjacent methods" | keep | drop `entrypoint=` and `helper_provenance`; schema v1 records | P1, P3.4 |
| … "instrumented dependencies remain precompilable" | keep | D04 dependents in the private depot | — |
| … "unmatched exclusions and activation mismatch fail" | keep | F-07 (now at load) and F-06 | P1 |
| … "child configuration cannot be spoofed or reused with a different token" | delete | no tokens (D16); replaced by F-04 and the C-14 descendant cases | P1 |
| … "exit status and inherited process state" | keep | `exit(37)` propagates through the `atexit` merge | — |
| … "tests may consume arguments and change working project" | keep | `Pkg.activate(original)` still loads the instrumented image (#113) | — |
| … "concurrent activations retain independent exclusions" | rewrite | becomes C-12 concurrency; drop the distinct-active-project assertion | P1 |
| … "reported DispatchDoctor skips and strict coverage" | rewrite | D11 does not count nested closures, so strict passes; exact records (#67) | P2.7 |
| … "dynamic outside-root include cannot escape instrumentation" | rewrite | C21: an include evaluated into an owned module at build time is instrumented and listed, so it is no longer an error | P2.8 |
| … "aliased includes cannot silently replace checked methods" | keep | F-16 | — |
| … "include_string aliases cannot bypass source coverage" | keep | F-16 | — |
| … "already-loaded target is rejected" | keep | F-05 | — |
| … trailing `include("test_launcher.jl")` | delete | — | P1 |
| `test_launcher.jl` (whole file) | delete | covers `test_original`, inert import, `source_root`, launch-state and tamper checks, all removed by O15, Design A and D16; replaced by C-10 | P1 |
| `test_gpu.jl` | keep | driver rewritten for Design A (P1); record-mode expectations (P3); unstable device code fails GPU compilation in both modes (C9) | P1, P3 |
| `test/gpu/Project.toml` | rewrite | path source, compat `"0.2"`, `julia = "1.13"` | P1 |
| `fixtures/test_support.jl` | rewrite | off runs comment out **both** lines; gate and skip idioms; drop `entrypoint` and `DCT_ENTRY_FLAGS`; private depot per fixture (#66); scrubbed `JULIA_LOAD_PATH` and `JULIA_PROJECT` plus one stacked-env fixture (#69); exact records (#67) | P1 |
| `fixtures/Target` | rewrite | compat `DispatchCheckup = "0.2"`, `julia = "1.13"` | P1 |
| `fixtures/JLLLoader` | rewrite | baremodule plus a `.pkg` include before the header (S6a) | P2.4 |
| `fixtures/{Dependency,Consumer,Skipped,GPU}` | keep | — | — |

Transitional rules. These states exist only on `redesign-0.2` and are never released: 0.2.0 ships only the O4 template and writes no DD key (S2 D24, S3.1).

- **DD expansion.** Until P2.1, the frozen walker still macroexpands DD's `@stable`. The P1 injected `LocalPreferences.toml` therefore keeps today's forced DD keys for the target. P2.1 deletes both.
- **Canaries.** Until P2.1, the per-image canary pair and the two P1 activation canaries are built through that DD path, inside the private submodule or a DC-owned module. They are never built by `Core.eval` into a user module (#78). A canary registers when it throws `TypeInstabilityError`; the hook calls it inside `try`/`catch`. The `_show_warning(::Site, …)` shape check of S3.2 (a) lands with R7 in P2.1.
- **Records.** From P1.2 until P2.2, `SINK` holds the frozen walker's own records, now pushed at evaluation time. Each is a `Record` whose class is 0.1's kind (`instrumented`, `excluded` or `unsupported`), with 0.1's reason text, the name, module path, file, line and the matched exclusion key. P2.2 replaces them with S3.5's classes, site ids and statement inventory.
- **Matching and `require_all`.** Until P2.6 and P2.7, `unstable=` keeps 0.1 matching, and `require_all` keeps 0.1 semantics: any `unsupported` record fails the run.
  - The P1.4 call layer parses and canonicalises the full O6 grammar, so the D45 table already holds canonical spellings. The P1 walker converts each entry to 0.1's key string: a bare `:foo` to `"foo"` (0.1 prefixes the target), and a qualified entry to its dotted text with operators unquoted (`Symbol("Base.:+")` to `"Base.+"`).
  - A form (d) site entry raises "not available yet" during argument validation until P2.6, like `mode=:record`.
  - There is no stage-1 validation before P2.6. An entry with no `excluded` record fails validation at finalizer step 5, as 0.1's `validate_exclusions!` did; F-07 stays `@test_broken` until P2.6.
- **Members.** Until P3.2, members write nothing under `R`. In P1's `:error` mode their instabilities throw where they occur.
- **Report.** Until P3.4, the final report carries the v1 core fields that P1 has (`schema_version`, `status`, `exit_code`, `failures`, `[run]`, `[phases]`), with the records under `[info]`.

### Regression corpus: finding → test

- **Groups.**
  - **C** contract, **W** walker differential, **T** wrapper and template unit, **L** loading or environment fixture, **R** report and output;
  - **H** harness hygiene, applied in the harness itself;
  - **K** weekly corpus, **X** weekly Julia canary, **G** manual GPU tier;
  - **M** moot, no test; **D** documentation review item.
- **Payloads.** Only the source, the test body and the expected outcome are vendored from each repro. Generated `env/` manifests are regenerated. The differential oracle supplies the production baseline where none was recorded.
- **Not archived.** `julia-forward-compat-2074`, the repros for #99–#102 and the refuted #108/#109, is not in `$AUDIT`. The Julia canary must recreate those cases.

| # | grp | test asserts | repro (`$AUDIT/…`) |
|---|---|---|---|
| 0 | C | activation in a suite that also has test/client.jl, under Pkg.test: runtests.jl body runs once; a failing @test fails the run (no entry discovery, D15/D30) | launcher-review-k7q2/clientjl |
| 1 | L | history independence: cp of a pkgdir asset then write leaves the checkout as production does; U1-C-U2 byte-identical tree (D13, D51) | arch-review-22778/e23_symlink_writethrough |
| 2 | W | global/local definitions: top-level, let, local, for-loop, struct-body forms load and check (SF #2) | transform-review-k7q2/cases/c01_global |
| 3 | W | unknown decorator left unwrapped, recorded blind spot; unstable= acknowledges it (D06) | transform-review-k7q2/cases/c15_adjoint |
| 4 | W | DD @stable begin...end block stripped, includes inside mapped, block options kept (D07/D09) | transform-review-k7q2/cases/c12_stableinc |
| 5 | W | dead @static/if branch: definitions inactive, unstable= entry reported inactive, image fresh vs cached give same records (D05) | compat-dogfood-x7k2/repro-deadbranch-requireall |
| 6 | W | qualified nested unstable= entry independent of load order (O6 grammar b) | excl-x7k2/names4 |
| 7 | W | runtime include of a file outside the root from a package function runs natively, recorded informational (SF #7, conflict 21) | semantics-review-x7q2/run/runtimeinclude |
| 8 | L | named active project with [extensions]: activation succeeds (D24) | env-review-k7q2/B3 |
| 9 | C | interactive session refused before side effects; non-interactive run never calls exit() except to replace 0 (D14/D30) | launcher-review-k7q2/base |
| 10 | C | static hygiene: compat table equals O14; twin on 1.13 (D20) | api-review-k7q2/ci_matrix/ToyCI |
| 11 | T | checked helper called in a @generated generator never throws in the pure context; event recorded with context generator (D03) | dogfood-staticarrays-18393/repro_generator |
| 12 | W | unstable= entry for an unloaded extension method reported inactive, not an error (O6) | dogfood-staticarrays-18393/repro_ext_exclusion |
| 13 | T | simulator keeps source lines: anonymous and operator command literals, @__DIR__ (O4 template parameter) | transform-review-k7q2/cases/c20_dirmask |
| 14 | W | iterate/getproperty/setproperty! methods recorded by-design, not instrumented (D08) | transform-review-k7q2/cases/c06_ignored |
| 15 | W | __init__ (root and submodule) not wrapped, recorded by-design (D08) | transform-review-k7q2/cases/c11_init |
| 16 | W | source @unstable region around include: included definitions not wrapped (D07/D09) | transform-review-k7q2/cases/c13_unstableinc |
| 17 | W | literal top-level @eval body instrumented; non-literal eval recorded blind spot (D11/D44) | transform-review-k7q2/cases/c10_skipped |
| 18 | W | Method.line equals each definition's own first line incl. @doc and inner constructors (SF #18) | transform-review-k7q2/cases/c08_docline |
| 19 | T | union_limit= applies to DC wrappers only; source @stable keeps its own union limit (O6/D09) | dd-coupling-17901/existing |
| 20 | T | unstable inner constructor raises/records TypeInstabilityError, stable one passes (O4 template parameter) | dd-coupling-17901/ctor |
| 21 | T | Type-valued keyword: DD check first, singleton retry, leniency recorded (D43) | dd-coupling-17901/cmp |
| 22 | T | load-time self-test of every DD runtime helper fails closed naming the DD version; DD-main canary (O4) | - |
| 23 | W | extension owned by PkgId, not bare name; foreign extension with same name not owned (SF #23) | excl-x7k2/extcollide |
| 24 | W | unstable= key with '..' parsed structurally, covers all its methods (O6) | dogfood-intervalsets-18034/repro_lines |
| 25 | W | include_string alias, Core.include, invokelatest(Core.eval) bypasses: load error or audit finding (D44) | include-review-29383/aliasbypass |
| 26 | L | test file including a package-source path into Main is not a bypass (SF #26, D46 owned-module observer) | include-review-29383/testinc |
| 27 | W | local variable / keyword named include is left alone (SF #27) | semantics-review-x7q2/run/includekw |
| 28 | L | tests writing .jl/.toml under pkgdir(Target) behave as in production (D13) | env-review-k7q2/W |
| 29 | L | TMPDIR inside the package dir: activation works (moot under D13; smoke) | env-review-k7q2/V |
| 30 | L | package with custom entryfile under an active-project case-4 run loads the right entry (SF #30, D24) | env-review-k7q2/B2 |
| 31 | R | stale passed report replaced by 'incomplete' placeholder at activation; crash leaves incomplete (D22) | launcher-review-k7q2/base (t_stale_ok.jl) |
| 32 | M | no file symlinks exist (D13); Windows contract leg; grep invariant | - |
| 33 | L | Scratch/lazy-artifact/log writes land in the user depot (D17) | portability-perf-cdd5740d/scratch |
| 34 | C | guard child receives the D18 flag table (threads, check-bounds, depwarn, project); `-p` is refused at activation (D18/D50, D12) | launcher-review-k7q2/base (t_procs.jl) |
| 35 | C | SIGTERM/SIGINT: guards skipped, report interrupted; guard child dies with parent (PDEATHSIG) (D50) | launcher-review-k7q2/base (t_sleep.jl) |
| 36 | C | pre-activation code that cd()s or push!(ARGS) runs once and is not compared (D30) | testsuite-review-q7k2/selfact |
| 37 | L | second checked run reuses images of target and dependents from the private depot (D04/D17) | portability-perf-cdd5740d/depcache |
| 38 | C | import closure after using Test is exactly the 7 modules (D20) | api-review-k7q2/ext_dates |
| 39 | H | static rule: no @__DIR__-derived runtime paths in src (Design A lesson) | api-review-k7q2/reloc |
| 40 | C | target in DC's load closure is an activation error naming the closure (SF #40) | lifecycle-1431/selfdep |
| 41 | W | infer=false module: by-design skip, report says nothing checkable; process-wide disable trips the canary (D08/O10) | semantics-review-x7q2/run/noinfer |
| 42 | K | activation overhead measured in corpus (moot under D13: no tree copy) | portability-perf-cdd5740d/assets |
| 43 | G | GPU env uses path source; assert pathof(DispatchCheckup) inside the checkout (SF #43) | testsuite-review-q7k2/gpu_probe.jl |
| 44 | C | repeat call: same options idempotent; different options error naming the option (SF #44) | lifecycle-1431/repeat |
| 45 | C | descendant env: D12 export present in children; guard child scrubbed of DISPATCH_CHECKUP* apart from the DISPATCH_CHECKUP_RUN=guard:<pid> marker, load/depot/project variables restored (D12/D31) | lifecycle-1431/subflags |
| 46 | L | dependents rebuilt into the private depot; user-depot production caches untouched (D04/D17); a dependent built lazily after activation lands under a distinct slug and is reported lazy | arch-review-22778/e5_dependents |
| 47 | L | target loads from the instrumented image (load-mode assertion); StaticArrays mul! case in corpus (D04) | dogfood-staticarrays-18393/repro_source_loading |
| 48 | W | bare :foo matches extension and Base-extending definitions named foo in owned modules (O6 grammar a) | dogfood-staticarrays-18393/repro_ext_exclusion |
| 49 | C | twin fixture runs Aqua.test_all with the README snippet incl. [compat] DispatchCheckup (D51) | dogfood-staticarrays-18393/StaticArrays |
| 50 | W | require_all counts only blind spots not listed in unstable=; DD limitations are reported with locations and counts, never counted; real-package check in corpus (D11) | docs-claims-k7q2/strictmacro |
| 51 | R | report uses real names for every site; no <generated>/<callable> placeholders (D44/D11) | dogfood-orderedcollections-4511/probe/methods_probe.jl |
| 52 | L | symlinked TMPDIR and symlinked depot: identity comparisons pass (path-identity helper, D25) | include-review-29383/pkgdirinc_symtmp |
| 53 | W | foreign-qualified key Symbol("Base.getindex") matches by callee spelling or emission-time resolution (O6 grammar c) | excl-x7k2/names |
| 54 | W | definition named by a parametric Union alias loads; key falls back to spelled name (SF #54) | excl-x7k2/names5-unionalias-crash |
| 55 | W | first-class include (broadcast, foreach, invokelatest, @eval include): mapped or actionable error with line (SF #55) | include-review-29383/bcast |
| 56 | W | missing include target raises production's SystemError (SF #56) | include-review-29383/missinginc |
| 57 | L | non-UTF-8 file name in the package tree does not break activation (moot under D13; smoke) | env-review-k7q2/K/e2e |
| 58 | L | ext/Name/Name.jl preferred over ext/Name.jl like Base (SF #58) | env-review-k7q2/G |
| 59 | C | banner and guard output ordered: flush before every spawn (SF #59) | launcher-review-k7q2/base (t_order.jl) |
| 60 | C | suite exiting 0 before loading target: distinct 'target never loaded' failure (SF #60) | launcher-review-k7q2/base (t_early0.jl) |
| 61 | M | lazy facade deleted (Design A) | api-review-k7q2/partial_load |
| 62 | L | source_path(), @__FILE__, @__DIR__ agree on the original file at load (D13) | semantics-review-x7q2/probe1 |
| 63 | L | unreadable directory in the package tree does not break activation (moot under D13; smoke) | portability-perf-cdd5740d/unreadable |
| 64 | C | guard child with '//' or relative TMPDIR runs (lesson of removed test_original, D50) | portability-perf-cdd5740d/origsym |
| 65 | K | walker cost on large packages within budget (likely moot under O6 matching) | portability-perf-cdd5740d/perf (prof.jl) |
| 66 | H | every fixture uses a private depot; no assertion reads ~/.julia | testsuite-review-q7k2/cache_race.jl |
| 67 | H | assert exact report records, never a regex over output | testsuite-review-q7k2/failprop/out.log |
| 68 | H | runtests.jl group selection accepts every group; no hidden includes | testsuite-review-q7k2/repo/test |
| 69 | H | fixtures run with JULIA_LOAD_PATH/JULIA_PROJECT scrubbed; one stacked-environment fixture | testsuite-review-q7k2/repo/test/test_probe.jl |
| 70 | D | README states production-identical metadata (D13) | docs-claims-k7q2/aqua |
| 71 | C | docstring lists exactly the six keywords (compare with Base.kwarg_decl) | docs-claims-k7q2/baremod |
| 72 | W | generator/comprehension closures classified like -> and do-blocks (SF #72, D11) | dogfood-orderedcollections-4511/checkup_run3.toml |
| 73 | W | quoted templates inside function bodies are not definitions (SF #73) | dogfood-simpletraits-17683/repro-quoted-def |
| 74 | M | test_original deleted (O15); activation inside the guard child is inert (covered by C guard tests) | dogfood-staticarrays-18393/repro_test_original_args |
| 75 | R | @test_nowarn around `using Target` passes in a checked run; declined forms summarized by reason (D22) | dd-coupling-17901/cmp |
| 76 | M | tokens/digests deleted (D16) | launcher-review-k7q2/base |
| 77 | T | wrapper overhead budget for Function-typed arguments measured and documented | semantics-review-x7q2/run/perf |
| 78 | W | one hidden submodule per image; Aqua ambiguity/unbound-args on target unchanged (D46) | semantics-review-x7q2/run/ambig |
| 79 | K | warm checked-run overhead budget measured in corpus; second run reuse in L-37 | portability-perf-cdd5740d/perf |
| 80 | T | compat module: one smoke test per Base/Pkg/DD internal symbol (SF #80) | - |
| 81 | M | subprocess design replaced (D30) | - |
| 82 | T | Type{<:Type} argument maps to its singleton, template divergence 8 (S3.1 R9, D21 divergence list); matches production on Julia 1.13.2 / DD 0.4.29 | dogfood-orderedcollections-4511/dd_empty.jl |
| 83 | W | per-definition key :foo => "src/file.jl:LINE" leaves sibling methods checked (O6 grammar d) | dogfood-orderedcollections-4511/checkup_run3.toml |
| 84 | C | unmatched unstable= entry fails at load, before tests run, with nearest candidates (O6) | dogfood-datastructures-9371/run3.log |
| 85 | R | report lists DD decline reasons per site and declared-but-unloaded extensions (D22) | dogfood-intervalsets-18034/trim |
| 86 | T | record mode: caught, logged, task and finalizer instabilities all recorded; run fails at end (D03) | swallowed-instabilities-19885/base |
| 87 | L | ReTestItems/Distributed workers load the instrumented image and their records merge (D12) | test-runner-frameworks-k7q2/rti_falsepass |
| 88 | C | pathof/pkgdir report the checkout at precompile time, in __init__ and at run time (D13/D46) | analysis-tools-shim-1706/jetlog |
| 89 | T | record mode runs the real body; mode=:error throws at the call (D03) | swallowed-instabilities-19885/base |
| 90 | L | ReTestItems runtests(MyPkg) works in a checked Pkg.test (D13) | test-runner-frameworks-k7q2/rti_pkgtest |
| 91 | L | load-path order preserved except the prepended env (D24) | implicit-environments-11471 |
| 92 | D | README explains what a detection is and when it is reported (D03) | - |
| 93 | R | Aqua stale_deps blind set warned; analyzer guards run in original= (D32) | analysis-tools-shim-1706/stale |
| 94 | M | source_root deleted (O15) | analysis-tools-shim-1706/remedy_b |
| 95 | C | file listed in original= included in the checked process is an error (D32) | analysis-tools-shim-1706 |
| 96 | L | worker-only unstable= matches and records count (D12) | test-runner-frameworks-k7q2/ptr_ext |
| 97 | L | no active project: env built from the real load path, pwd() never read (D24) | implicit-environments-11471/h |
| 98 | L | stopenv honoured: checked run fails where production fails (D24) | implicit-environments-11471 |
| 99 | X | Julia pre/nightly canary: locate_package_env shape (latent; repro not archived) | julia-forward-compat-2074/run-1.14-compatonly-dd (not archived) |
| 100 | W | Expr(:module) read via args[end-1]/args[end] (version-agnostic); 1.14 shape in canary | julia-forward-compat-2074/run-1.14-loadspec-only-dd (not archived) |
| 101 | X | Julia pre/nightly canary: mapper must not define a const in Base (latent; repro not archived) | julia-forward-compat-2074/run-1.14-min (not archived) |
| 102 | X | Julia pre/nightly canary: [syntax] edition preserved (latent; repro not archived) | julia-forward-compat-2074/syntax-implicit-compat (not archived) |
| 103 | T | allow_unstable in tests: suppressed instabilities recorded as `allowed`, with site; they never fail the run (D03) | swallowed-instabilities-19885/base |
| 104 | C | overlay Project.toml byte-identical to the original (D13) | analysis-tools-shim-1706/compat |
| 105 | W | @testitem-local definitions classified test-only, not package definitions (D06) | test-runner-frameworks-k7q2/tir2 |
| 106 | L | preferences set for an [extras] package from a stacked env survive (D24/D45) | implicit-environments-11471/f3 |
| 107 | C | guard child with @script in LOAD_PATH runs (lesson of removed test_original, D50) | implicit-environments-11471/g |
| 108 | M | refuted | julia-forward-compat-2074/run-1.12.6 (not archived) |
| 109 | M | refuted | julia-forward-compat-2074/DC112T (not archived) |
| 110 | C | JET report_opt in an original= guard passes; the checked process skips it (D02) | analysis-tools-shim-1706/jetrt |
| 111 | T | Zygote gradient through a checked function infers and stays within budget (D42; weekly AD job) | ad-frameworks-f4de5967/repro_zygote_inferred |
| 112 | L | active project is the user's project; DrWatson/CondaPkg idioms see it (D24); CondaPkg case in corpus | active-project-state-3662b810/conda |
| 113 | L | Pkg.activate(original) after activation still loads the instrumented package (D24) | active-project-state-3662b810/idioms |
| 114 | L | generators see the image's world; source-load fallback path gives the same records (D04) | source-load-pkgimage-90d54fc3/b_divpkg |
| 115 | L | closed-module eval at load fails in the checked run exactly as in production (D04) | source-load-pkgimage-90d54fc3/d_closedeval |
| 116 | R | overlay build failure says whether the original also fails to precompile (D04) | source-load-pkgimage-90d54fc3/a_genpkg |
| 117 | W | top-level load-time lambdas/do-blocks never wrapped, recorded by-design (D08) | source-load-pkgimage-90d54fc3/k_toplevel_do |
| 118 | L | image reuse across runs (same tests as L-37) | source-load-pkgimage-90d54fc3/proto |
| 119 | C | @main entry: validation and report run after main returns (D30) | entry-output-tests-7ae19516/ (base/main_*.jl) |
| 120 | R | no DD load-time warning reaches the test logger (O4); covered with #75 | entry-output-tests-7ae19516/base (warn_*.jl) |
| 121 | L | julia --project=pkgdir(Target) subprocess works (D13) | entry-output-tests-7ae19516/base (sub.jl) |
| 122 | L | subprocess with the active project joins the run or loads the original; never an uncontrolled overlay (D12) | entry-output-tests-7ae19516/base (sub.jl) |
| 123 | W | block/module macros (@muladd, @fastmath, @views, @reexport, Trixi-style) recursed; includes mapped (D07) | decorator-survey-1393581b (pkgs3/ToyBlock) |
| 124 | W | decorator table: the 25 survey shapes classified as vetted/unknown (D06) | decorator-survey-1393581b/policy.diff |

Totals: W 32, L 29, C 22, T 13, M 8, R 7, H 5, K 3, X 3, D 2, G 1.

### Real-package corpus (weekly)

- **Packages.** The dogfood set: Combinatorics, OrderedCollections, DataStructures, IntervalSets, SimpleTraits, Compat, Accessors and StaticArrays. Versions are pinned in `test/corpus/packages.toml`, and the pins are refreshed monthly.
- **Each package.** Run production `Pkg.test` and checked `Pkg.test` (`mode=:record`) in the same job, then:
  - require equal Test counts;
  - diff the instability list against last week's artifact;
  - record the activation overhead, the cold and warm image build times and the private-depot size, against GitHub's 10 GB cache limit;
  - record load-time detections lost relative to 0.1 (C14).
- **Internal consumer repositories.** Resolved (default): public CI runs only public packages. The private consumer repositories join the corpus only on the maintainer host (run manually or by cron there), never in the public workflow, so no token is stored in public CI (open point 4). GodelaAMGX_jll, which is public, keeps its checked suite on the maintainer's GPU host (S6a).

**Rationale.**

- Nothing tests the hard requirement today. With 0.1.2 merely declared, `Pkg.test` re-resolved and moved MacroTools from 0.5.15 to 0.5.16 (`$AUDIT/D26-test-strategy-m3k8/out`).
- Running each repro as its own checked-plus-production subprocess pair would take an estimated 60–80 minutes per PR. In-process walker cases cost 0.3–2.4 s each after the first JIT.

---

## D27 Branching and release (O15)

**Decision.** The redesign is built on `redesign-0.2` and merges once to `main` as 0.2.0, tagged `v0.2.0`. There is no registration and no deprecation path.

**Requirements**

- **P0 (done).** `v0.1.2` is tagged at 2fd0449. `redesign-0.2` branches from it (`git tag` lists `v0.1.2`; HEAD is 2fd0449).
- **Branch work.**
  - All work lands as PRs into `redesign-0.2`, one per phase task and one per walker policy, never mixing shell and walker semantics in a single PR (D01).
  - The first P1 commit sets `version = "0.2.0-DEV"`. The merge PR sets `"0.2.0"`.
- **`main` is frozen until the merge.** An emergency 0.1.x fix lands on `main` as 0.1.3 with a tag and is merged forward into `redesign-0.2`.
- **Deleted outright, with no stub, error hint or `register_error_hint`:** `test_original`, `source_root`, the `entrypoint=` keyword, the lazy facade and its bridges (O15, S4).
- **Merge.** Resolved (default): use a merge commit, not a squash, so that per-policy history stays bisectable (open point 10). Tag `v0.2.0` (annotated) on the merge commit. The GitHub release notes are the CHANGELOG 0.2.0 section, which lists every breaking change.
- **Consumer coordination.** Merging 0.2.0 makes every consumer's resolution fail ("empty intersection … 0.1.2"). The sweep follows the private consumer migration plan (S6b, maintained outside this repository), which holds the per-repository detail. The proposed engineering sequence is below. Two parts of it are open for the owner (open point 12): the rollout path for the consumer integration PRs that are still open, and the step 4 fallback.
  1. **During M**, open one migration PR per consumer. It sets compat `"0.2"`, temporarily sets `rev = "redesign-0.2"` and rewrites the call sites (S4 "Migrating from 0.1"). It may drop the consumer's own `report = get(ENV, …)` read of a report-path variable under the reserved `DISPATCH_CHECKUP_` prefix, but need not: DC ignores unknown `DISPATCH_CHECKUP_*` variables and lists them in the banner, and consumers may keep reading their own variables in test code (S4 D31; Resolved (default)). Its CI must be green, and GodelaAMGX_jll's checked suite must pass on the L40S host.
  2. Merge DC and tag `v0.2.0`.
  3. The same day, flip each consumer PR to `rev = "main"` and merge it.
  4. Proposed fallback, open for the owner (open point 12): a consumer that cannot migrate that day pins `rev = "v0.1.2"` until it can. Apart from step 1's temporary preparation rev, this would be the only sanctioned deviation from `rev = "main"`.
- **Consumer inventory.** The owner counts 13 consumers. A scan of the maintainer's local checkouts finds 14 internal consumer repositories with 17 `Project.toml` files (17 packages) carrying `DispatchCheckup = "0.1.2"`, the public GodelaAMGX_jll among them. Some repositories carry more than one package. The per-repository list is in the private consumer migration plan (S6b, maintained outside this repository).

  Resolved (default): all 14 repositories (17 packages) are in scope and are swept. Seventeen test files reference `test_original` or `source_root`. Three migrations are non-mechanical: a consumer that calls `test_original` with no argument, a consumer with a test file that calls `test_original` on itself, and a consumer with an environment-group selector (`$AUDIT/D33-removed-api-migration-m5t8`).

**Rationale.** Consumers track `rev = "main"` on purpose (O0). A loud resolution failure is safer than a silent behaviour change. Preparing the PRs against the branch bounds the red window to one session.

**Tests.** Covered by M's exit criteria: every consumer PR is green against `redesign-0.2` before the merge, and no `Project.toml` in the inventory still carries `"0.1.2"` afterwards.

---

## D38 Licensing and attribution

**Decision.** DC stays MIT. The check-wrapper template derived from DD 0.4.29's `_stabilize_fnc` (O4) is an Apache-2.0 file inside the MIT repository, attributed per Apache-2.0 §4(a)–(b). Everything else follows a "reference, don't copy" rule.

**Requirements** (land in P2.1 together with the template)

- **Header of the template file.** It must begin with:
  - `# SPDX-License-Identifier: Apache-2.0`;
  - the source (DispatchDoctor.jl v0.4.29, `src/stabilization.jl`, `_stabilize_fnc`);
  - the original authorship ("Miles Cranmer and contributors");
  - a "Modified by DispatchCheckup" statement summarising the changes: recorder, AD prologue, Type-keyword gate, long tuples, simulator source lines, `Base.:!`, inner constructors, `Type{<:Type}` singletons (divergence 8, #82).
- `LICENSES/Apache-2.0.txt` holds the verbatim license text.
- `THIRD_PARTY_NOTICE.md` lists each Apache-2.0 file with its upstream, version and license.
- **No Apache `NOTICE` file.** DD ships none, so §4(d) does not apply.
- **README license line:** "MIT, except files listed in THIRD_PARTY_NOTICE.md (Apache-2.0)."
- **Code adapted from Julia Base**, if any, gets a header carrying Julia's MIT copyright line.
- **Everything else references by call, never by copy:** DD's runtime helpers, `TypeInstabilityError`/`showerror` for message text, and Base's loader functions.
- **Contributing.** Add one line to `CONTRIBUTING.md`: "Adapted third-party code? Add a header and a THIRD_PARTY_NOTICE.md entry."
- **AI disclosure** is optional (O0). If written, it must state only what is true.
- **Upstream PRs to DD** must state AI assistance in their description.

**Rationale.** No line of 0.1 `src/` is copied from DD, Base or the stdlib (an n-gram check found 0 of 828). DD has no NOTICE file and no filled copyright line. The template prototype follows `_stabilize_fnc` step for step, so it is a derivative work (`$AUDIT/D38-provenance-licensing-p4k7`).

**Tests.** `hygiene` greps every `src/` file for an Apache SPDX tag and asserts that each one is listed in `THIRD_PARTY_NOTICE.md`, and that `LICENSES/Apache-2.0.txt` exists.

---

## D39 Audits of packages you do not own

**Decision.** There is no public runner API, export or app in 0.2.0. The README documents a zero-code recipe. An internal injector, outside semver, drives the weekly corpus.

**Requirements**

- **README "Auditing a package you don't own":**
  1. Copy the package.
  2. Add DC as a test dependency (`[extras]/[targets]` or `test/Project.toml`) with `[sources] url + rev = "main"`.
  3. Put the two lines at the top of `test/runtests.jl`, or set `DISPATCH_CHECKUP=on` if the package already uses the gate.
  4. Run `Pkg.resolve(); Pkg.test()`.

  The result is the report's instability list (record mode), not pass or fail. The audited package's guards run in the checked process, so expect noise.
- **`test/corpus/inject.jl`** (not exported, not documented as API):
  - handles the extras, `test/Project.toml` and `[workspace]` layouts;
  - rewrites relative `[sources]` paths to absolute ones;
  - uses `DISPATCH_CHECKUP=on` instead of injecting when activation lines already exist;
  - prints the manifest diff;
  - maps report paths back to the original tree.
- **Never build a runner** on a hand-made `Pkg.test` sandbox or on `julia_args=-L preload.jl`. `Pkg.test` resets `DEPOT_PATH` and sets `JULIA_LOAD_PATH="@:<tmp>"`.
- **Reusability.** The activation call must work unchanged on line 1 of a copied tree. It resolves paths from its own file and assumes nothing about git or the checkout location.

**Rationale.** A 31-line injector plus an ordinary `Pkg.test` caught a planted instability in all three layouts. The preload approach was verified not to work (`$AUDIT/D39-out-of-tree-runner-p6w3`).

**Tests.** A per-PR smoke test runs the injector on toy packages in the extras, `test/Project.toml` and workspace layouts and finds the planted instability. The weekly corpus is the scale test.

---

## D01 Phase plan

The D01 phases are kept: P1 builds the shell and the seam with the walker frozen, P2 lands one PR per walker policy, and P3 adds the recorder, the audit and the corpus. Two stages are added around them: P0 (done) and M (merge).

### P0 — done

- `v0.1.2` is tagged at 2fd0449, and `redesign-0.2` exists.

### P1 — shell and seam, walker frozen

**P1.0 Prototypes (first task, 1.5–2 days).** Nothing in P1.3 is committed until P1.0's results are written into `docs/design.md`.

(a) **Depot layout (the D17/D47 open point).**

- **Matrix:**
  - runtime `DEPOT_PATH` order: user depots then the private depot (D17), against the private depot first (D47);
  - overlay location: inside the directory on `DEPOT_PATH`, a sibling of it under `.dispatchcheckup/`, or outside the user depot;
  - mirrors: none, or `dev/` plus `packages/`;
  - target location: a checkout outside any depot, `U/dev`, `U/packages/<slug>`, or a secondary depot in a stacked `JULIA_DEPOT_PATH`;
  - packages: target with an extension, a dependent, and the `--compiled-modules=no` fallback.
- **Lifecycle:**
  - run 1 builds, runs 2 and 3 reuse;
  - restore the depot tarball after a fresh checkout (`julia-actions/cache` style);
  - `Pkg.gc()`;
  - three concurrent runs;
  - alternating checkouts;
  - a config change and its revert.
- **Measure:**
  - `Rejecting` and "distributed over multiple depots" lines under `JULIA_DEBUG=loading`;
  - `cachepath` of the target, its extension and the dependent, which must be in the private depot;
  - files created under `U/compiled/v1.13/<Name>`, which must be zero;
  - `pathof` and `pkgdir`.
- **Decision rule.** Choose a layout with zero rejections on runs 2 and 3, zero user-depot writes for the target and its extensions (and, in runs with no lazy dependent, for the dependents), every target location covered, and no links.
- **Pre-check while writing this section** (Julia 1.13.2, toy package; script derived from `$AUDIT/D47-persistent-state-cbe97c0c/exp1.sh`; build with the private depot first, run with the user depot first; scratch copy passed to the orchestrator for archiving):
  - Overlay inside the directory placed on `DEPOT_PATH`, target in `U/dev`: the image was rejected on run 2 ("is for file @depot/overlays/… not file …"). Base then **recompiled the instrumented target into the user depot**. Mirroring `dev/` did not help.
  - Overlay in a sibling directory (`.dispatchcheckup/overlays/`, with only `.dispatchcheckup/depot/` on `DEPOT_PATH`), no mirror: the image was reused from the private depot on runs 2 and 3, with zero user-depot files, for targets in `U/dev`, in `U/packages` and outside any depot.
  - Mechanism: Base relativises each include path to the first `DEPOT_PATH` entry it lies under (`loading.jl:3562`). It rejects a cache whose files resolve to more than one depot (`:3700-3725`).
  - Provisional layout (S2 D17+D47 is normative): the private root `<first user depot>/compiled/v1.13/.dispatchcheckup/`, with one key directory `v1/<Name>-<uuid8>-<crc32c8>/` per checkout holding `key.toml`, `overlay/` (the shims and the Project copy) and `depot/`, which is the only directory ever placed on `DEPOT_PATH`. The pre-check used one shared `depot/` beside `overlays/`; both keep the rule that nothing an image includes may live under the directory on `DEPOT_PATH`, and P1.0 picks between them.
  - D47's "must mirror" was measured with the private depot first at runtime, which D17 rejects. A target in a secondary depot is unverified.

(b) The critic's verify-first list:

- in-process activation under the `Pkg.test` sandbox, in both the `[extras]` and `test/Project.toml` layouts;
- an error in the precompile worker reaches the test process intact, rather than becoming the exit-125 fallback;
- `__init__` order for extension images;
- `Pkg.gc` and `julia-actions/cache` keep `compiled/v1.13/.dispatchcheckup` (`$AUDIT/critic-completeness-q7r3`).

**P1.1 Contract-first (2 days, parallel lane).** The twin harness and C-01 to C-07. C-04, C-06 and C-07 fail against 0.1.2 and turn green with the D20 table. F-01 and F-02 land with P1.2.

**P1.2 Seam (1.5 days).**

- A typed `CompileConfig` that build workers read from the D45 preference table. It is never a literal in the shims, which stay config-free (S2 D13, D45; C0).
- The D45 table in the per-run `LocalPreferences.toml`.
- The S2 seam types and the `CONFIG`/`SINK` lookup that replaces 0.1's `config_file` argument (S2 "Seam types"), with the file split of S2 "Source layout".
- A record sink in the private submodule. The markers become pure: every expansion-time record of the frozen walker becomes an emitted push into `SINK` (S3.13 P1), under the transitional rules after the triage table.
- A compat module for every Base and DD internal, with one smoke test per symbol (SF #80).
- The O14 window and the D20 floors.
- The DD helper self-test (O4). P1 covers S3.2 (a) for the R1 names, plus the unstable `first(::Vector{Any})` and stable `x + 1` canaries. The other (b) canaries land with the features they exercise (P2.1, P3.1).
- Deletion of the facade, `implementation.jl` and `launcher.jl`, and of everything in `environment.jl` except what D24 keeps.

**P1.3 Image subsystem (4–6 days).** D04, D13, D17, D45, D46, D47 and D24:

- the minimal overlay with original identity;
- the hook submodule;
- the up-front build with output capture;
- the load-mode assertion;
- keys and GC.

**P1.4 Activation shell (2.5–3.5 days).**

- D30 in-process activation.
- D29 call layer: the six O6 keywords with validation. Until P3.1, the branch's signature default is `mode = :error` (the docstring says so; `Base.kwarg_decl` and C-16 are unaffected), and an explicit `mode=:record` raises "not available yet". This deviation is branch-only and is never released. `unstable=` keeps 0.1 matching until P2.6 (transitional rules below).
- D31 and D40 values.
- D14, D15, D16 and D49.
- The D12 export and descendant join.
- The D22 placeholder report.
- The finalizer steps of S2 D30, in conflict 11's order: merge, audit, validate, report, guards, final status. DC stops no worker itself, because the frameworks' hooks run first (S2 D30 step 3). The merge and the audit are stubs until P3.2 and P3.3.

**P1.5 Guard runner (1.5–2.5 days).** D02, D50 and D18, plus the D32 error for an `original=` file included in the checked process. This includes the guard-child `ENV` (the pre-activation snapshot minus every `DISPATCH_CHECKUP*` name, plus `DISPATCH_CHECKUP_RUN=guard:<pid>`, with `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` and `JULIA_PROJECT` restored), inert activation inside the guard child and its descendants, and the D50 reaper, the second `atexit` hook, which only kills a guard child still alive after a signal (Resolved (default), C-10).

**P1.6 Triage and CI (2.5–3.5 days, parallel lane).**

- The test triage above, with the fixture driver and integration tests rewritten for Design A.
- `ci.yml`.
- The Linux path variants for the D25 path-identity helper. The helper itself lands in P1.3 with `store.jl`, because `R0` and the keys need it (S2 "Source layout").
- The GPU environment path source.

**P1 exit criteria**

- P1.0 results are recorded and the layout is chosen. The S1 open point 1 is closed.
- `ci.yml` is green: contract on 3 operating systems, full on ubuntu and macOS.
- The walker oracle (0.1 `test_instrumentation.jl` assertions) passes with mechanical changes only.
- C-01 to C-18 and F-01 to F-17 pass, except C-17's `:record` half and the tests whose features land later, which are marked `@test_broken` with their phase.
- No 0.1 facade, launcher, snapshot, token or fingerprint code remains. Pkg, SHA and UUIDs are out of `[deps]`.

### P2 — walker policies (one PR each, each landing its regression rows)

| task | content | days |
|---|---|---|
| P2.1 | O4 check-wrapper template, with parity to 0.1 in `mode=:error`. Template parameters: D23 long tuples, simulator source lines (#13, #18), `Base.:!`, inner constructors (#20), D43 Type keywords, `union_limit` (O6/D09). Delete `_expand_stable`, the four output rewrites and the DD preference forcing. Regenerate the S3.2 canaries and the per-image canary pair through the template, and add the `_show_warning(::Site, …)` shape to the self-test. D38 attribution files land in the same PR | 2–3 |
| P2.2 | D05 evaluation-time records in S3.5 form (site ids, deduplication, statement inventory); dead branches inactive | 1.5–2 |
| P2.3 | D06 and D07 shared built-in table (no user keyword), D07 strip of DD `@stable`/`@unstable` regions | 2.5–3.5 |
| P2.4 | D08 by-design skips, with O10/S6a for JLLs (vetted `@generate_main_file`, infer-flag rule); GodelaAMGX_jll checked suite on the host | 1–1.5 |
| P2.5 | D09 source annotations (C6) | 0.5–1 |
| P2.6 | D10 with the O6 grammar (a)–(d), load-time validation with nearest candidates, inactive entries, the multi-module note (C20). Resolved (default): an `unstable=` entry for a definition that carries its own explicit source `@stable` keeps DD's native check, as in production; members of a source `@stable` block listed in `unstable=` are emitted unwrapped (S3.10) | 2.5–3.5 |
| P2.7 | D11 classes; `require_all` counts only blind spots not listed in `unstable=`. DD limitations are reported with locations and counts and are never counted (Resolved (default), D11 reading of O6) | 1.5–2 |
| P2.8 | walker SF batch (table below), the C21 include rule, Expr(:module) reading | 1–1.5 |

**P2 exit criteria**

- Every W and T row whose phase is P2 is green.
- No `@stable` macroexpansion and no DD preference write remain (grep).
- `THIRD_PARTY_NOTICE.md` is present.
- GodelaAMGX_jll reports "nothing checkable" and passes (S6a).
- A manual run of the dogfood set loads.
- The MacroTools activation floor (D20) is re-measured on the refactored walker, and the check is updated if the result moves.

### P3 — recorder, audit, corpus

| task | content | days |
|---|---|---|
| P3.1 | D03 recorder through DD's `_show_warning`. `mode=:record` becomes the default and `:error` stays an option, as a runtime switch. Never throw in pure contexts (C5). Hot-path budget. D42 AD-transparent prologue. Zygote test | 3–4 |
| P3.2 | D12 durable per-process record files and their merge (C11); Distributed, ReTestItems and Malt/ParallelTestRunner fixtures | 1.5–2 |
| P3.3 | D44 method-table audit, with the D11 audit class | 2 |
| P3.4 | D22 schema v1 and console summary; D32 blind-set warning; SF #85 and the import-closure note | 1–2 |
| P3.5 | `weekly.yml` and canaries; the corpus and injector (D26, D39); the Windows `@test_broken` list | 2.5–3.5 |

**P3 exit criteria**

- C-17 passes in full and every P3 row is green.
- The recorder fast path allocates nothing after the first record.
- Zygote infers through a checked function.
- The audit reports zero false positives on the StaticArrays-style corpus case.
- `weekly.yml` has run end to end once, with failures filed as issues.

### M — merge

| task | content | days |
|---|---|---|
| M.1 | Documentation SF: README as a user guide (keyword table, gate and CI recipe, guards, report schema, troubleshooting by error string, audit recipe, license line), `docs/design.md`, `CHANGELOG.md`, the `dispatch_doctor` docstring. No Documenter | 2–3 |
| M.2 | Qualification: GPU tier log, corpus run, 3-OS contract, GodelaAMGX_jll | 1 |
| M.3 | Consumer migration PRs against `redesign-0.2` (14 repositories, 3 of them non-mechanical) | 3–6 |
| M.4 | `version = "0.2.0"`; merge commit; tag `v0.2.0`; flip and merge the consumer PRs | 0.5 |

**M exit criteria**

- All required checks are green on the merge commit.
- The GPU log is attached to the release.
- No consumer `Project.toml` still carries `"0.1.2"`.
- Every consumer's CI is green on `rev = "main"`, or, if the owner allows the merge-day fallback (open point 12), the consumer is pinned to `v0.1.2` with an issue.

### Straightforward fixes by phase

"Moot" means Design A, D13, D30, O4 or O15 removes the defect's mechanism. The row then says what, if anything, remains.

| SF | fix | phase | status |
|---|---|---|---|
| #2 | `global`/`local` definitions, including the simulator gensym | P2.8 | adopt |
| #7 | runtime include falls back to native outside the root or an unowned module | P2.8 | adopt (C21) |
| #13 | simulator source restore | P2.1 | moot as a rewrite: O4 template parameter |
| #18 | each definition's own first line | P2.8 + P2.1 | adopt |
| #23 | extension ownership by PkgId (`Base.uuid5`) | P1.2 | adopt |
| #26 | include observer scoped to owned modules | P1.3 | adopt (D46) |
| #27 | local `include` binding left alone | P2.8 | adopt |
| #30 | entryfile from the located entry | P1.3 | adopt (D24) |
| #31 | `incomplete` placeholder report | P1.4 | adopt (D22, C19) |
| #35 | parent watchdog for spawned processes | P1.5 | partly moot (no checked child, D30); applies to the guard child |
| #40 | refuse targets in DC's closure | P1.2 | adopt (smaller closure, D20) |
| #41 | stable canary for process-wide disabled inference | P1.3 | adopt (D46; S6a late-flag amendment) |
| #43 | GPU path source, `pathof` assertion | P1.6 | adopt |
| #44 | repeat activation: idempotent or error | P1.4 | adopt (same process; no child) |
| #49 | README `[compat]` in the extras snippet | M.1 | adopt (C-05) |
| #52 | canonicalize roots once with `realpath` | P1.3 (helper), P1.6 (path variants) | adopt (D25) |
| #54 | Union-alias names | P2.8 | adopt |
| #55 | first-class include | P2.8 | adopt |
| #56 | missing include raises SystemError | P2.8 | moot (no snapshot, D13); keep the regression test |
| #57, #63, #29 | tree-walk robustness | — | moot (no tree copy, D13); smoke tests only |
| #58 | extension entry lookup order | P1.3 | adopt (shim per extension) |
| #59 | flush before every spawn | P1.5 | adopt (guard spawn) |
| #60 | distinct "target never loaded" status | P1.4 | adopt |
| #65 | `_generic_name` scan cost | P2.6 | likely moot under O6 matching; measure |
| #66–#69 | test hygiene | P1.6 | adopt; `test_launcher.jl` deleted |
| #72 | generator/comprehension closures | P2.7 | adopt |
| #73 | quoted templates | P2.2 | adopt |
| #75, #120 | DD warnings in test output | P1.3 / P3.4 | largely moot (O4: DD's `@stable` is never expanded); keep worker-output capture (D04) and the by-reason summary |
| #78 | one private submodule per image | P1.3 | adopt (D46) |
| #80 | one compat module with per-symbol smoke tests | P1.2 | adopt |
| #85 | precise skip reasons | P3.4 | adopt (reasons now come from the template) |
| #99–#102 | 1.14 port items | P2.8 / X | Expr(:module) reading now; the rest is latent, in the canary |
| #104 | never inject `[compat]`/`[deps]` into the overlay Project | P1.3 | moot (byte-identical copy, D13); assert it (C-11) |
| #119 | `@main` entries | P1.4 | moot as a fix (falls out of D30's `atexit`); keep the test |
| import closure | extensions triggered only by DC's closure, reported "loaded by DispatchCheckup" | P3.4 | adopt |
| #39 lesson | no `@__DIR__`-derived runtime paths in eager code | P1.2 | adopt (hygiene grep) |
| docs (#71, #92, #95, #70, #116) | README user guide, `design.md`, CHANGELOG, docstring | M.1 | adopt; no Documenter |

### Decision → phase index

| phase | decisions |
|---|---|
| P1 | D01 (seam), D02, D04, D12 (export, join), D13, D14, D15, D16, D17, D18, D20, D22 (placeholder), D24, D25, D26 (contract, triage), D29→O6, D30, D31, D32 (included-file error), D36 (`ci.yml`), D40, D45, D46, D47, D49, D50, D51, O14 |
| P2 | D05, D06, D07, D08 + O10, D09, D10→O6, D11, D21→O4, D23, D38, D43 |
| P3 | D03, D12 (aggregation), D22 (schema v1), D26 (corpus), D32 (blind set), D36 (`weekly.yml`), D39, D42, D44 |
| M | D27→O15, D39 (README), documentation SF |
| dropped or superseded | D19 stub (O14); D21 "range + assertions" (O4; C23 void); D29's eight-keyword signature (O6); D33 stubs and hints (O15; the sweep lives in M and in the private consumer migration plan, S6b, maintained outside this repository); D48 `waive=` (O6; C7 void); C16's window override |

### Dependencies and critical path

- **Critical path**, single lane: P1.0 → P1.2 → P1.3 → P1.4 → P1.5 → P2.1 → P2.2 → P2.3 → P2.6 → P2.7 → P3.1 → P3.2 → P3.3 → P3.4 → M.2 → M.3 → M.4. This chain, not the volume of code, bounds wall-clock time. Only M.3's finalization is on the path; drafting the consumer PRs runs in parallel.
- **Hard edges:**
  - P1.0 → P1.3 (layout);
  - P1.2 → everything (seam);
  - P2.1 → P3.1 (recorder is a template parameter);
  - P2.2 → P2.6 → P2.7 (D10 needs D05; D11 needs D10);
  - P2.3 → P2.6 (the macro table decides what is checkable);
  - P3.1 → P3.2 (aggregation needs the recorder);
  - P3.3 → the D11 audit class;
  - P3 exit → M.3 (consumer CI needs the default mode).
- **Parallel lane:**
  - P1.1 and P1.6 alongside P1.2–P1.5;
  - P2.4, P2.5 and P2.8 alongside P2.3 and P2.6;
  - P3.5 alongside P3.1–P3.4;
  - M.1 and drafts of the M.3 PRs from the P2 exit on.

### Effort

The work is executed by coding agents, so effort is estimated as agent wall-clock time. Writing the code is not the bottleneck. Two things are: the serial dependencies on the critical path, and Julia test runtime. 0.1's suite takes about 8 minutes, and a checked StaticArrays corpus run about 30.

| phase | agent wall-clock | bounded by |
|---|---|---|
| P1 | 2–4 h | P1.0 depot prototype; integration test runs |
| P2 | 3–5 h | one walker policy at a time, each landing its review repros as regression tests |
| P3 | 3–5 h | recorder and aggregation; corpus runs |
| M | 1–3 h | consumer test suites, run in parallel |
| **total** | **≈ 1–2 days**, plus the owner's review | |

Earlier drafts gave 17–25 and 45–63 *human developer-days*. Those figures are not a planning input for agent execution and were removed.

---

## Risk register

| id | risk | L | I | mitigation | check owned by |
|---|---|---|---|---|---|
| R1 | Overlay and depot layout split `@depot` relocation, so images rebuild every run and instrumented images leak into the user depot (seen in the pre-check) | H if mislaid | H | sibling overlay layout; P1.0 matrix; post-suite `pkgorigins` audit (D17); C-02 and C-12 | P1.0 prototype; C-12 per PR |
| R2 | Base internals change in a 1.13.x patch or in 1.14: `PkgOrigin.path`, `precompilepkgs`, `include_callbacks`, `identify_package_env`, submodule-first `__init__` | M | H | one compat module with per-symbol smoke tests; window check; forward-port canary | unit tests per PR; weekly `julia-pre`/`nightly` |
| R3 | DD runtime helpers renamed, or a 0.4.30+ change in their semantics | M | H (fail closed) | activation self-test naming the DD version; `dd-main` canary; `_stabilize_fnc` hash; `dd-floor` leg | weekly `dd-main` and `dd-floor` |
| R4 | In-process prepend not effective under the `Pkg.test` sandbox or in descendants, giving a silent false pass | M | H | P1.0(b); load-identity check (F-13); C-18 both modes | P1.0; C-18 per PR |
| R5 | A worker error swallowed into the exit-125 source-load fallback | M | M–H | load-mode assertion; worker failure file in the run directory (D46); F-12 | F-12 per PR |
| R6 | Hard-requirement regression: compat creep or an import side effect makes commented-out runs differ | M | H (O1) | per PR: twin on 3 OS, history on ubuntu and macOS; C-06; C-07 | `contract` job |
| R7 | DD weakdep compat (EnzymeCore 0.6–0.8, ChainRulesCore 1) blocks or re-resolves users' environments when new majors ship | M | M | `twin-latest`, headroom check, upstream report | weekly |
| R8 | The merge breaks every consumer's resolution | H (certain) | M (loud) | PRs prepared against the branch; same-day flip; `v0.1.2` pin fallback if the owner allows it (open point 12) | maintainer, M.4 |
| R9 | The three non-mechanical consumer migrations (the private consumer migration plan, S6b, maintained outside this repository) and the consumers' report-path variable under the reserved prefix take longer | H | M | start drafts at the P2 exit; standalone guard files; F-08 catches mis-splits; unknown `DISPATCH_CHECKUP_*` variables are ignored and listed in the banner, so the variable need not be removed on merge day | maintainer, M.3 |
| R10 | Effort overrun against the D01 estimate | H | M (calendar) | phase gates; parallel lane; owner reviews the estimate at the P1 exit | owner at each exit |
| R11 | Private-depot growth against the 10 GB CI cache limit; a future `Pkg.gc` touching `compiled/` | M | L–M | 30-day stamp GC (D47); `DISPATCH_CHECKUP_DEPOT`; `Pkg.gc` survival test; reused/rebuilt line in the report | C-12; corpus size metric |
| R12 | Concurrent runs race on shim writes, so a run tests another checkout's code | M | H | key on `crc32c(realpath root)` plus `key.toml`; atomic writes; per-run env (D47) | C-12 concurrency |
| R13 | The recorder perturbs production (allocation, timing, `@test_logs`) or fails in generator, finalizer or GPU contexts | M | M–H | zero-allocation fast path; no throw or IO in pure contexts (C5, C8); `@noinline` call in DD's dead branch (C9) | T rows; GPU tier |
| R14 | GPU tier skipped (manual) | M | M | release checklist; `gpu` PR label; log attached | maintainer |
| R15 | Windows path identity (case, 8.3 names, separators) gives false passes in experimental runs | M | M | `experimental` stamp; identity helper; required contract tier | `windows-full` weekly |
| R16 | Corpus churn makes the weekly job noisy | H | L | pinned versions; issue bot; monthly pin refresh | maintainer weekly |
| R17 | Private consumer sources or tokens exposed through public CI | M | H | public CI runs only public packages; private consumer corpus legs run only on the maintainer host (manual or cron there); no token is stored in public CI | maintainer |
| R18 | Widened bare-name matching silently over-excludes migrated configurations (C20) | M | M | multi-module note in the summary; CHANGELOG; migration review | maintainer, M.3 |
| R19 | Apache-2.0 attribution missed for the derived template | L | M | SPDX/notice hygiene test | `hygiene` per PR |
| R20 | 1.14 is released while DC fails to precompile or import there, putting ERROR blocks into consumers' `Pkg.test` output (compat `"1.13"` admits 1.14) | M | H | no top-level internals; window-gated workload; weekly `pre` contract canary; a failure is a release blocker | weekly `julia-pre` |
| R21 | The DD helper self-test or the template's first-use JIT adds seconds to every checked run | M | L | precompile workload in the window; self-test cost measured (0.1 s warm) | corpus overhead metric |

---

## Open points

1. **Depot layout.** P1.0 must confirm the sibling-overlay layout, including a target in a secondary (stacked) depot and cache restore after a fresh checkout. If mirroring turns out to be needed, D25's junction rules and Windows data-safety subset return.
2. **Preferences in `[deps]`. Settled.** S2 D45 reads the table through Preferences' public `load_preference`, so Preferences stays in `[deps]` (O14).
3. **Consumer inventory. Resolved (default).** The owner says 13 consumers; the scan finds 14 internal consumer repositories and 17 `Project.toml` files. All 14 repositories (17 packages) are in scope for M.3 (D27).
4. **Internal consumer corpus. Resolved (default).** Public CI runs only public packages. The private consumer repositories join the corpus only on the maintainer host (manual or cron there), so no token is stored in public CI (D26, R17).
5. **Test-only forks. Resolved (default).** The current Aqua and CheckConcreteStructs `[sources]` fork pins stay in `[extras]` as they are (status quo). Switching to registered Aqua 0.8 and CheckConcreteStructs 0.1, which were verified to pass on an eager stub (`$AUDIT/D27-distribution-release-k3q9`), is out of scope for 0.2.
6. **MacroTools floor. Resolved (default).** The activation-time fail-closed floor `pkgversion(MacroTools) >= 0.5.12` is adopted in addition to the DD `>= 0.4.29` floor, although it goes beyond O14's text. It matches S4's compat table. It is re-measured after the walker refactor (P2 exit criteria).
7. **Weekly `dd-floor` leg. Resolved (default).** It is not in the owner's list; the recommended weekly leg with DD pinned to `=0.4.29` is adopted (D36).
8. **Effort. Resolved.** Estimated as agent wall-clock time, about 1–2 days plus the owner's review (see Effort). If time must be cut, the candidates are the corpus breadth and the Windows `@test_broken` burn-down, not any owner decision.
9. **Repro archive gap.** `julia-forward-compat-2074` (#99–#102, #108, #109) is not archived.
10. **Merge style. Resolved (default).** The redesign merges to `main` with a merge commit, not a squash (D27).
11. **Unsupported operating systems. Resolved (default).** Activation fails closed on any OS other than Linux, macOS and Windows, as the D25 challenger proposed (F-17).
12. **Consumer rollout path and `v0.1.2` pin fallback (open for the owner).** The owner decides how the consumer integration PRs that are still open roll out to 0.2 (the D27 sequence is the proposal; the per-repository paths are in the private consumer migration plan, S6b, maintained outside this repository), and whether a temporary `rev = "v0.1.2"` pin is allowed as a merge-day fallback for a consumer that cannot migrate that day. O0 says consumers track `rev = "main"` on purpose, so D27 step 4, the R8 mitigation and the M exit criterion that relies on the pin wait on this decision.
13. **Owner items. Settled.** The only owner items for 0.2 are O0, O1, O4, O6, O10, O14 and O15.

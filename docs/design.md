# DispatchCheckup design

**Goal.** Test a package as if DispatchDoctor's `@stable` wrapped its whole module, without
touching its source, and with no trace of DispatchCheckup once the two lines at the top of
`test/runtests.jl` are commented out.

## Activation

`dispatch_doctor(:MyPackage; ...)` runs in the test process, before `using MyPackage`. It
does no work outside that call: importing DispatchCheckup only loads it.

1. **Refuse** if `MyPackage` is already loaded, if `mode` is not `"error"` or `"warn"`, if
   the loaded DispatchDoctor is not the fork (its `DISPATCHCHECKUP_PATCHLEVEL`, at least
   3), or if DispatchDoctor is disabled on this Julia version. A second call with the same options
   does nothing; any other second call is an error.
2. **Locate** the package as Base would load it (`Base.identify_package`,
   `Base.locate_package`, so `entryfile` and `JuliaProject.toml` are honoured), and its
   extensions' entry files (in Base's lookup order).
3. **Match `unstable=`** against the sources: parse the entry files, follow the `include`
   calls whose path and module can be worked out statically (strings, `@__DIR__`,
   `dirname(@__FILE__)`, `joinpath`, interpolation, loops over literal file names; the
   module of `Base.include(Sub, ...)` and `Sub.include(...)`), and check that every entry
   selects a definition (check 3). The error lists the include calls it could not follow.
4. **Write the overlay** in `<depot>/scratchspaces/<DispatchCheckup UUID>/overlays/`, one
   directory per checkout and configuration (named by a hash of the package's shim, which
   holds both): a byte-identical `Project.toml` and a shim at the path of each entry file.
   A shim is a few lines that require DispatchCheckup and call `_load_checked`, with the
   configuration (`unstable`, `mode`, `union_limit`) as a literal. Files are only
   rewritten when their content changes, so precompiled images survive from one run to
   the next, and runs with other options, even concurrent ones, never share shims. The
   scratch space comes from `Scratch.get_scratch!`, which records it as used by
   DispatchCheckup's project: `Pkg.gc` deletes the spaces that no existing project is
   recorded as using, and keeps this one while that DispatchCheckup is installed, so a
   `Pkg.gc` in any process (Pkg runs one on its own after a `Pkg.update`) leaves the
   overlays of running suites in place.
5. **Write a per-run environment** and put it first on `LOAD_PATH` (and in
   `JULIA_LOAD_PATH`, for the Julia processes the tests start): a `Project.toml` with the
   package in `[extras]`, a copy of the active manifest in which the package's path is the
   overlay (and DispatchCheckup is among its dependencies), and a
   `LocalPreferences.toml` with DispatchDoctor's mode, union limit and codegen level
   (`"debug"`) for the package. Being first, these preferences win over any others. The
   active project stays what it was (when it came from `LOAD_PATH`, as under `Pkg.test`,
   it is set explicitly first, and exported as `JULIA_PROJECT` for the Julia processes the
   tests start).
6. Check what DispatchDoctor resolves for the package (check 2), set
   `DISPATCH_CHECKUP=checked` and `DISPATCH_CHECKUP_ENVIRONMENT` (the per-run
   environment), start the Julia process for the `original=` files (below), and install a
   package callback and an `atexit` hook.

The test's own `using MyPackage` then precompiles and loads the package as usual, except
that Base finds the shim. `_load_checked` points `Base.pkgorigins` at the original entry
file (so `pkgdir` and `pathof` report the checkout) and includes the original file in
place with a mapexpr. No source file is copied, so `@__DIR__`, relative `include`s and
data files work unchanged. When the package is loaded from its precompiled image, the
shim does not run; instead, the mapexpr puts a hidden module first in the package's
module (and in each extension's), whose `__init__` runs before every other `__init__` and
does the same `pkgorigins` update, in every process. It also records the path Base loaded
the package from, for check 1. That module, `var"#DispatchCheckup"`, is the one trace of
DispatchCheckup inside the checked package: tools that match a package's submodules with its
source (ExplicitImports) report it, so such checks belong in `original=` files.

A Julia process started by a checked run loads the checked package through the inherited
`JULIA_LOAD_PATH`. If it calls `dispatch_doctor` itself, the inherited environment is first
removed from `LOAD_PATH` and `JULIA_LOAD_PATH`, so that it is checked with its own options,
as if started by an ordinary run.

`dispatch_doctor` itself only normalizes its arguments; the work is in `_activate`, which
has concrete argument types and is precompiled with the rest of the activation path.

## The transformation

The entry file runs in `Base.__toplevel__`, so the mapexpr marks each statement of the
package's module with a macro; when the macro expands, inside the module and after the
statements before it have run, it applies three steps (the same steps are the mapexpr of
every included file):

1. wrap the definitions selected by `unstable=` in DispatchDoctor's `@unstable`; a
   definition behind macros is wrapped together with them (`@unstable @generated function
   ...`), as `@generated`, `@ccallable` and others need a bare definition;
2. send the `include` calls (`include(path)`, `include(mapper, path)`, `Base.include(mod,
   path)`, `Base.include(mapper, mod, path)`, `Core.include(mod, path)`, `Mod.include(path)`,
   `Mod.include(mapper, path)`) through the same mapexpr, so the exclusions reach included
   files (`x.include(...)` where `x` turns out not to be a module runs as written);
   `include_string`, higher-order uses such as `foreach(include, files)` and include calls
   generated by macros are left alone and are not checked;
3. call the fork's `stabilize_expression(mod, ex; ...)`: exactly what `@stable` does to a
   module body, with options resolved as `@stable` resolves them in `mod`.

## The three checks

1. **Loaded from the overlay.** The package callback checks that the package and each
   extension came from its shim (the path recorded by `_load_checked` or the hidden
   `__init__`). Otherwise, if the package never loads, or if an extension whose packages
   are all loaded did not load (Base only logs that error), the process exits with a
   nonzero status.
2. **The requested options.** `DispatchDoctor.stabilization_options` must return the
   requested mode and union limit for the package, at activation and for every module
   the shims load.
3. **Every `unstable=` entry matches**, at activation, before any test runs. An unmatched
   entry is reported with the nearest names.

## The `original=` files

They run in one fresh Julia process with the environment, load path, depot path, active
project and working directory from before activation (the `DISPATCH_CHECKUP*` variables
removed), with the same command-line flags and threads. Activation starts it as its last
step, so it runs alongside the checked suite: both are mostly single-threaded, and the run
takes about as long as the longer of the two instead of their sum. It takes the environment
as it is at activation (variables that the suite sets later do not reach it) and the test
process's color setting (`get(stdout, :color, false)`), as its stdout and stderr go to one
file. Its first lines make both line-buffered: Julia writes a file through an IOStream,
which buffers by block, so a process killed by a signal (a native fault, the OOM killer)
would lose what it printed last; line-buffered, it keeps every complete line. The `atexit`
hook waits for it, prints that file after the suite's output, in one block, and makes the
exit status the first nonzero one of the suite, the checks and the process (128 plus the
signal, if a signal killed it). A process that cannot start makes `dispatch_doctor` throw;
an error while waiting for it, or while printing its output, fails the run (an error while
waiting prints the file first).

A suite killed by a signal (Julia then runs the exit hooks with code 128, in a state where
waiting for a process or writing to a stream can hang) kills the process at once instead,
with `SIGKILL` sent by its process id, and leaves the exit status alone. On Linux, the
process also asks the kernel to send it `SIGKILL` when the test process dies
(`PR_SET_PDEATHSIG`), and ends at once if the test process is already gone. That covers
the cases no hook can: a suite killed with `SIGKILL`, and a signal that comes while the
hook is already waiting for the process (Julia runs each hook once). Elsewhere, the process
then runs on until its files end.

The two processes share the machine, the GPU included. With `concurrent = false`, the hook
starts the process instead, once the suite is done, as DispatchCheckup 0.2.1 did: with the
environment as it is then and the test process's stdout and stderr. That is for a suite
that must have the machine to itself: GodelaAMGX's suite fills its GPU to 64 MiB short of
full for about a second to make AMGX run out of memory, while its guard files build an
AMGX solver on the GPU and solve with it, so either could fail the other.

## The DispatchDoctor fork

[AzamatB/DispatchDoctor.jl, branch `dispatchcheckup-v2`](https://github.com/AzamatB/DispatchDoctor.jl/tree/dispatchcheckup-v2)
includes upstream main through `4559c329` (still version 0.4.29), the pending P5 fix, and
the integration changes below. The rejected P2 change has been removed. DispatchCheckup's
`[sources]` pins the fork to a commit, and Pkg also uses it for
packages that add DispatchCheckup by URL or path. The fork keeps DispatchDoctor's name but
has its own UUID. With the registered UUID, every environment
with DispatchCheckup would resolve the registered DispatchDoctor to the fork, for the
package, its dependencies and its tests, even with the two lines commented out (and an
environment that fixed the registered release could not have the fork at all). As a
separate package, nothing loads the fork in such a run. In a checked run, both are loaded:
the registered release's `allow_unstable` still pauses the checks (P8), but its
`register_macro!` does not reach them (that of `DispatchCheckup.DispatchDoctor` does), and
the checks throw the fork's `TypeInstabilityError`, a different type from the registered
one. The package's own `@stable` and `@unstable` blocks are recognized by name and left to
the registered release. The merged fixes alone do not replace the fork: DispatchCheckup
still needs its integration APIs and independent package identity.

Merged upstream fixes:

- **P1** ([#131](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/131)) The check
  builds the tuple of argument types at its known size and passes it to inference as one
  `Tuple` type, so a call with more than 32 arguments no longer allocates, and `Type`
  arguments cost nothing extra.
- **P3** ([#133](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/133)) The inferred
  copy of a function keeps its source lines, so `@__DIR__`, `@__FILE__` and command
  literals mean the same as in the real function; the definition appears in the stack
  trace of a `TypeInstabilityError`.
- **P4** ([#134](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/134)) The generated
  check qualifies `!` and `Val`, so it works in a `baremodule`.
- **P6** ([#136](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/136)) An argument
  `::Type{K}` where `K` is itself a type of types (`DataType`, say) is specialized on
  correctly, which removes a false positive.
- [#140](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/140) prevents a Julia 1.10
  inference crash with `Union{}` arguments. The upstream benchmark and stack-frame test
  additions in #138 and #139 are included too.

**P2** ([#132](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/132)) was rejected
upstream and is no longer included. Type-valued keywords use their ordinary inferred
types, matching upstream. Specializing them on their values could hide a real instability
when the type is only known at run time; `f(x; T = Float32)` is therefore no longer
automatically accepted merely because the actual value of `T` is a concrete type.

Remaining fork changes:

- **P5** ([#135](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/135), still open)
  No check in modules that turn inference off (`@compiler_options infer=false`, common in
  JLL packages), where every call would look unstable.
- **P7** The integration surface: `DISPATCHCHECKUP_PATCHLEVEL`,
  `stabilize_expression(mod, ex; ...)` (as above, without the "found no compatible
  functions" warning, so it can run on every expression) and
  `stabilization_options(mod; ...)` (check 2; `mod` can also be a package's UUID, for the
  check at activation, before the package is loaded). Apart from these, DispatchCheckup uses
  only DispatchDoctor's `@unstable` and `JULIA_OK`.
- The fork's own UUID (and its DynamicExpressions integration test pointed at it).
- **P8** The check is also off while the registered DispatchDoctor is loaded and its
  `allow_unstable` runs, as tests written against it expect. The fork captures that
  package's flag (its `Ref{Bool}`) once, at load: in the fork's `__init__` if the
  registered package is already loaded, else from a `Base.package_callbacks` hook when it
  loads. Only once a return type is found to be unstable (never on the stable path), the
  check reads the captured flag, with no lock and no lookup, so any number of threads can
  run checked code inside one `allow_unstable`. If nothing was captured (the package is
  not loaded, or its internals differ from those of 0.4.x), the fork's own flag decides.
  `DISPATCHCHECKUP_PATCHLEVEL` is 3.

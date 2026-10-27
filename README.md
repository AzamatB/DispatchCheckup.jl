# DispatchCheckup.jl

Run your package's tests as if [DispatchDoctor](https://github.com/MilesCranmer/DispatchDoctor.jl)'s
`@stable` were applied to the whole package, without changing its source code. Production
code, and test runs without DispatchCheckup, stay exactly as they are.

## Usage

Put two lines at the top of `test/runtests.jl`, before the package is loaded:

```julia
import DispatchCheckup
DispatchCheckup.dispatch_doctor(:MyPackage; unstable = (:foo, :bar))

using Test, MyPackage
# ... the existing tests
```

Every function of `MyPackage` (its module, submodules, included files and extensions) is
then checked: a call whose return type is not concrete throws DispatchDoctor's
`TypeInstabilityError` (that of the fork below), and the test that made the call fails.
Comment out the two lines and the run is an ordinary one, as if DispatchCheckup did not
exist.

## Installation

Add DispatchCheckup as a test dependency, with a `[sources]` entry and a `[compat]` entry
for it. In `test/Project.toml`:

```toml
[deps]
DispatchCheckup = "ca055ede-32eb-4961-937e-82d9c5ec6430"

[sources]
DispatchCheckup = {url = "https://github.com/AzamatB/DispatchCheckup.jl", rev = "main"}

[compat]
DispatchCheckup = "0.2"
```

With `[extras]` and `[targets]` in the package's `Project.toml`, put the UUID in
`[extras]`, add `"DispatchCheckup"` to `[targets].test` and use the same `[sources]` and
`[compat]` entries (Aqua's compat check wants the latter). Julia 1.13.3 or later is required. A
project that used DispatchCheckup 0.1 runs `Pkg.update("DispatchCheckup")` after changing
the compat entry; if Pkg still reports an empty intersection with 0.1.2, remove the old
record (`Pkg.rm("DispatchCheckup")`) and add it again.

DispatchCheckup needs a [fork of DispatchDoctor](https://github.com/AzamatB/DispatchDoctor.jl/tree/dispatchcheckup-v2)
(see [the design notes](docs/design.md)). Its own `[sources]` names the fork, and Pkg picks
it up from there. The fork has its own UUID, so it is a separate package that only
DispatchCheckup loads: with the registered DispatchDoctor's UUID, it would replace that
package in any environment that also has DispatchCheckup, even with the two lines commented
out. If your package, its dependencies or its tests use the registered DispatchDoctor, they
keep using it, in ordinary and in checked runs. In a checked run, the registered
`DispatchDoctor.allow_unstable` also pauses the checks, so tests that use it work unchanged.
The fork captures the registered package's flag once, when it loads, and the checks read
it without a lock or a lookup, so threads that run checked code inside one
`allow_unstable` (a `Threads.@threads` loop, say) are all paused. The errors that the
checks throw are the fork's `DispatchCheckup.DispatchDoctor.TypeInstabilityError`, which
the registered `DispatchDoctor.TypeInstabilityError` does not match (in `@test_throws`,
say).

## Options

```julia
dispatch_doctor(pkg::Symbol; unstable = (), original = (), concurrent = true, mode = "error",
                union_limit = 1)
```

`unstable` lists definitions not to check, as DispatchDoctor's `@unstable` would. An entry
is one of:

| Entry | Excludes |
| --- | --- |
| `:foo` | every definition named `foo`, in any module of the package or its extensions |
| `Symbol("MyPackage.Sub.foo")` | the definitions of `foo` in that module (or an extension module such as `Symbol("MyPackageDatesExt.foo")`), and those written as `MyPackage.Sub.foo(...)` |
| `Symbol("Base.getindex")` | the definitions written as `Base.getindex(...)` (operators as DispatchDoctor prints them, `Symbol("Base.:+")`, also work) |
| `:foo => "src/file.jl:42"` | the definition of `foo` that starts at that line (the path is relative to the package root) |

Any collection of entries works; a single Symbol or Pair is one entry. A definition behind
macros (`@generated`, `@inline`, a docstring, ...) is excluded together with them, as
`@unstable @generated function f(x) ... end` would be. Each entry must match a definition
in the package's sources, or the run stops before the tests start, with the nearest names
found. To find the sources, DispatchCheckup follows the include calls whose paths are
strings, `@__DIR__`, `dirname(@__FILE__)`, `joinpath` or string interpolation of these, or
a loop over literal file names; it lists the others in that error.

`mode` and `union_limit` are DispatchDoctor's `default_mode` (`"error"`, or `"warn"` to only
log instabilities) and `default_union_limit` (`2` accepts `Union{Float32, Float64}`, say).
DispatchCheckup sets them as the package's preferences for the run, so that a
`dispatch_doctor_mode = "disable"` preference cannot switch the checks off.

`original` lists test files that must see the ordinary package, such as JET or
allocation checks. They run in one fresh Julia process with the original environment and
package, which `dispatch_doctor` starts at once (with the environment as it is then), so
that it runs alongside the suite. At exit, the run waits for it and prints its output
(stdout and stderr, kept in a file meanwhile) after the suite's, in one block. The exit
status is the first nonzero one of the suite, DispatchCheckup's checks and that process, so
its failures fail the run. If the suite is killed by a signal, the process is killed too:
on Linux, whatever the signal and whenever it comes; elsewhere, not when the signal is
`SIGKILL` or comes while the run is already waiting for the process. Skip the files in the
checked suite:

```julia
DispatchCheckup.dispatch_doctor(:MyPackage; original = "guards.jl")
using Test, MyPackage
# ...
get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("guards.jl")
```

With `concurrent = false`, the files run after the suite instead, with their output as it
comes and the environment as it is then, for a suite that must have the machine to itself
while it runs: one that fills the GPU's memory for a moment, say, while its guard files use
the GPU too.

The guard files run with every checked run, so a suite that runs subsets should build the
`original=` list from its own selection (for example,
`original = "guards.jl" in selected ? ("guards.jl",) : ()`). The paths are
relative to the file that calls `dispatch_doctor`. `DISPATCH_CHECKUP` is `"checked"`
during a checked run, and in the Julia processes it starts: those load the checked package
too, ReTestItems' workers among them. A process that calls `dispatch_doctor` itself (a test
that runs `runtests.jl` again, say) is checked with its own options instead.

## In CI

Keep the ordinary test job, and add a job that turns the checks on with an environment
variable:

```julia
if !isempty(get(ENV, "DISPATCH_CHECKUP", ""))
    import DispatchCheckup
    DispatchCheckup.dispatch_doctor(:MyPackage; unstable = (:foo,))
end
```

```yaml
  checkup:
    runs-on: ubuntu-latest
    env:
      DISPATCH_CHECKUP: "1"
    steps:
      - uses: actions/checkout@v7
      - uses: julia-actions/setup-julia@v3
        with:
          version: "1.13.3"
      - uses: julia-actions/julia-runtest@v1
```

## What is checked

Exactly what DispatchDoctor checks when its `@stable` wraps a module: every function
definition at the top level of the package's code, with DispatchDoctor's own rules (for
example, it leaves out closures, generated functions, functions with `@nospecialize`
arguments and code inside `@eval` or quotes). Files included with `include(path)`,
`Base.include(mod, path)`, `Core.include(mod, path)`, `Mod.include(path)` and their mapper
forms are checked too.
Not checked: code loaded with `include_string`, higher-order uses of `include` such as
`foreach(include, files)` or `include.(files)`, and include calls that a macro generates
(such as JLLWrappers' wrapper files). Modules that turn inference off
(`Base.Experimental.@compiler_options infer=false`, as every JLL package does) are not
checked either, so a checked run of a JLL package checks almost nothing. The checks see
only the calls that the tests make. A definition that `@stable` cannot take makes the
package (or the extension) fail to load in the checked run; exclude it with `unstable=`.
Examples are `Base.@ccallable` and `CUDA.@device_override f(x) = ...`: DispatchDoctor
applies the macro to its inferred copy of `f` too (exclude it as `:f => "src/file.jl:LINE"`,
which keeps any other method of `f` checked). If the package itself uses DispatchDoctor,
its `@stable` and `@unstable` blocks are left to the registered DispatchDoctor. Its
`allow_unstable` pauses the checks too, but its `register_macro!` does not reach them: use
`DispatchCheckup.DispatchDoctor.register_macro!` in a checked run.

The DispatchDoctor fork includes upstream's merged fixes for wide calls, `@__DIR__` and
`@__FILE__` inside checked functions, `baremodule`s, `Type{K}` arguments where `K` is itself
a type of types, and Julia 1.10 inference with `Union{}` arguments. It also retains the
pending [#135](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/135) change to skip
checks in modules with inference turned off, plus the integration described above.

Type-valued keyword arguments now follow upstream's behavior: calls such as
`f(x; T = Float32)` can report an instability when the inferred keyword type is `DataType`.
The fork no longer includes the rejected [#132](https://github.com/MilesCranmer/DispatchDoctor.jl/pull/132)
change, which specialized these keywords on their values and could hide instabilities
when the type was only known at run time.

A checked run also fails, with a message, when:

1. the package or one of its extensions was not loaded from DispatchCheckup's overlay (for
   instance because it was loaded before `dispatch_doctor`, or from another environment),
   the package never loaded at all, or an extension whose packages were loaded did not load;
2. DispatchDoctor would not use the requested `mode` and `union_limit` for the package;
3. an `unstable` entry matches nothing.

## How it works

`dispatch_doctor` writes a small overlay for the package: a copy of its `Project.toml` and
one short file per entry point that loads the original source files, in place, with
DispatchDoctor applied to each top-level expression. A temporary environment, put first on
the load path, makes `using MyPackage` load the package from the overlay; the active
project stays the same. The checked package is precompiled as usual, and the image is
reused while the sources and the options stay the same. There is one overlay per checkout
and set of options, so concurrent runs with other options do not affect each other.
`pkgdir` and `pathof` report the original checkout, also in the package's `__init__` and in
Julia processes started by the tests. Checked errors are
`DispatchCheckup.DispatchDoctor.TypeInstabilityError`. See [docs/design.md](docs/design.md).

For `pkgdir` in `__init__`, the checked package and each extension get one hidden
submodule, `var"#DispatchCheckup"`. Tools that match a package's submodules with its source
report it: ExplicitImports' `check_no_implicit_imports` and `check_no_stale_explicit_imports`
throw an `UnanalyzableModuleException`. Run such checks as `original=` files.

## Development

```sh
julia --startup-file=no --depwarn=error --check-bounds=yes --project=. -e 'using Pkg; Pkg.test()'
julia --startup-file=no --depwarn=error --check-bounds=yes --project=. -e 'using Pkg; Pkg.test(test_args = ["gpu_test.jl"])'
```

The test items of `test/*_test.jl` run on [ReTestItems](https://github.com/JuliaTesting/ReTestItems.jl)
worker processes; `test_args` names the files whose items run. The suite needs a GPU: its CUDA
tests also check that the checked kernels compile to the same PTX as the ordinary ones. GitHub's
hosted runners have none, so the repository has no CI workflow: run the suite on a machine with
a GPU before merging.

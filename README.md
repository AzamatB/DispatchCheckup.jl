# DispatchCheckup.jl

Dispatch the doctor on call. Run [DispatchDoctor](https://github.com/MilesCranmer/DispatchDoctor.jl)
against a package during testing, without adding annotations to its production source.

```julia
import DispatchCheckup

DispatchCheckup.dispatch_doctor(:MyPackage; unstable=(:foo, :bar))

using Test
using MyPackage

# Existing tests
```

Put the activation call before importing the package under test. The names in
`unstable` identify `MyPackage.foo` and `MyPackage.bar`; their methods are excluded
from the inserted checks. An exclusion that matches no definition is an error.
Use a qualified symbol such as `Symbol("MyPackage.Nested.foo")` to exclude a
nested function without excluding the root module's `foo`.

For nonstandard drivers, `entrypoint="path/to/runtests.jl"` selects the test file
explicitly. `report="checkup.toml"` retains the coverage report after temporary
files are cleaned up. `require_all=true` turns recognized unsupported constructs
into errors; the default reports DispatchDoctor's documented skips visibly.

Comment out **only the activation line** to run ordinary tests. Importing
DispatchCheckup does not load DispatchDoctor, install loader hooks, change
preferences, or create an instrumented environment.

Install DispatchCheckup as a test dependency from its GitHub `main` branch:

```julia
using Pkg
Pkg.add(url="https://github.com/AzamatB/DispatchCheckup.jl", rev="main")
```

For a package using `test/Project.toml`, run this in the activated test project.
Keep the source declaration alongside the dependency:

```toml
[deps]
DispatchCheckup = "ca055ede-32eb-4961-937e-82d9c5ec6430"

[sources]
DispatchCheckup = {url = "https://github.com/AzamatB/DispatchCheckup.jl", rev = "main"}
```

For an extras/targets test environment, put the UUID in `[extras]`, include
`"DispatchCheckup"` in `[targets].test`, and use the same `[sources]` entry.
DispatchCheckup targets Julia 1.13 and depends on DispatchDoctor 0.4.29 or a
compatible release.

An activated run prepares a temporary package environment and starts a fresh
Julia test process. Julia still loads the target as a package with its original
UUID, so dependencies share its module and types. Instrumentation applies to
owned source, included files, nested modules, and loaded package extensions. The
temporary dependency graph supplies the checking tools; production metadata is
not rewritten. Large assets can be shared without copying an entire dataset.

The parent forwards the child's result and does not execute the suite a second
time. It reruns the test entrypoint from the beginning, so put activation near
the top, before test setup with side effects. The child preserves test arguments
and execution settings. Temporary preferences enable checking even when the
original environment disables it;
the original preferences remain unchanged. Instrumented package loading uses
isolated writable state and verifies that the intended source is loaded.
Tests that inspect original source files can call `DispatchCheckup.source_root(MyPackage)`;
it returns the original checkout during instrumentation and `pkgdir(MyPackage)`
otherwise, without activating checks.

DispatchDoctor checks inferred **return types for the signatures exercised by
the tests**. A function can return a concrete type while still doing dynamic
work internally. Keep JET, concrete-field, boxed-capture, allocation, and device
checks alongside this tool. Also retain an ordinary test run for production
performance measurements: instrumentation can change compilation and allocation
behavior.

The temporary instrumentation uses DispatchDoctor's `debug` code generation,
which retains the original function body alongside its inference simulator.
This preserves inference through parametric keyword constructors; the smaller
`min` wrapper can introduce boxed simulator captures in those constructors.

JET and allocation or source guards should inspect production code, rather than
the checker's reflective wrappers. Delegate those test files through the same
test entrypoint:

```julia
DispatchCheckup.test_original(test_args=["test_guards.jl"]) ||
    include("test_guards.jl")
```

The driver must accept the supplied selector and run its usual fixture setup.
For an environment-based selector, use
`DispatchCheckup.test_original(env=["MY_TEST_GROUP" => "guards"])`.
The helper starts a fresh process with the original resolved project, load path,
depot, package source, and execution flags; it does not resolve dependencies.
Only that authenticated ordinary controller bypasses the recursive activation
call. A nonzero child exit fails the checked run with the same exit status.
Controller and project/load-path/depot variables cannot be overridden through
`env`. The checked target is loaded before delegation if the driver has not
imported it yet.

When activation is commented out, `test_original` returns `false` without
loading DispatchDoctor or starting a subprocess, so the existing include runs
normally. It also returns `false` inside the ordinary child, preventing
recursion. The report records these runs under `original_tests`, with their
selectors, source/environment identity, exit status, and validation result.
These records establish ordinary-source test results, not additional
DispatchDoctor-exercised signatures.

DispatchDoctor intentionally does not instrument every Julia construct.
Recognized skips appear as diagnostics in the coverage report.
Generated functions, some macro-generated definitions, and local closures need
particular attention. An active-check witness, package identity checks, and
exclusion validation prevent an apparently successful run with checking disabled.
The report counts annotated definitions and unsupported syntax sites, not
exercised argument signatures. A checked outer function can also have a warning
about an unchecked local closure. An unloaded extension or an uncalled method
has not been tested.

Direct `include`, `Base.include`, and `Base.include_string` calls, including their
mapper forms, are supported. Included files must be inside the package tree.
Snapshots copy `.jl` and `.toml` files; other files are shared assets and cannot
be included as Julia source. Custom `include` bindings and detected loader
bypasses fail with a diagnostic. Arbitrary
reflection, dynamically generated code, and definitions created in separate
worker processes are not exhaustively covered. `require_all=true` rejects
recognized gaps in loaded source; it is not a proof of complete runtime coverage.
JLLWrappers platform-loader macros map their selected source includes too. The
private JLL test overlay enables inference for those checks; third-party
generated loader helpers remain explicitly reported coverage gaps.

CUDA kernels with stable checked calls can compile successfully. A checked
device function with an unstable return may instead fail GPU compilation when
DispatchDoctor's host-side error path is retained. This is not a device-native
replacement for CUDA inference diagnostics. Use explicit exclusions where
appropriate, and qualify GPU behavior with actual device tests.
The checker preserves argument-type tuples for kernels with many arguments.
CUDA device overrides and other method-table overlays are retained as explicit
coverage gaps: DispatchDoctor's host inference cannot safely check their separate
method tables. Ordinary kernels and the corresponding host methods remain checked.

The temporary environment is a testing mechanism, not an operating-system
sandbox. Package and test code retain their ordinary filesystem permissions.
DispatchCheckup does not rewrite the original package sources; it cannot prevent
arbitrary tested code from writing to paths that code explicitly opens.

Develop and verify this package with:

```sh
julia --startup-file=no --depwarn=error --project=. -e 'using Pkg; Pkg.test()'
```

The test fixtures declare the GitHub `main` source. Tests of an unpublished
checkout use Julia's ordinary temporary test resolver to select that checkout;
local sibling paths are not committed as dependency sources.

The optional CUDA suite has its own environment, also sourced from GitHub
`main`. Once that branch contains the implementation, run it with:

```sh
julia --project=test/gpu -e 'using Pkg; Pkg.instantiate()'
DISPATCHCHECKUP_GPU_TESTS=1 julia --project=test/gpu test/runtests.jl test_gpu.jl
```

Set `CUDA_VISIBLE_DEVICES` to select a GPU for an independent run. The CPU suite
does not require CUDA.

"""
Run DispatchDoctor checks in a temporary package environment without changing
the package's production source. Importing DispatchCheckup performs no setup.
"""
module DispatchCheckup

public dispatch_doctor, source_root, test_original

const _implementation_lock = ReentrantLock()

function _implementation()
    lock(_implementation_lock) do
        if !Base.invokelatest(isdefined, @__MODULE__, :Implementation)
            Base.include(@__MODULE__, joinpath(@__DIR__, "implementation.jl"))
        end
        return Base.invokelatest(getglobal, @__MODULE__, :Implementation)
    end
end

"""
    dispatch_doctor(package::Symbol; unstable=(), kwargs...)

Run the current test entry point against an instrumented view of `package`.
Call this before importing the package under test. Unqualified names in
`unstable`, such as `(:foo, :bar)`, select `MyPackage.foo` and `MyPackage.bar`
when `package == :MyPackage`.

The enabled run uses a fresh process and temporary package environment. The
parent forwards the child's exit status instead of running the tests twice.
Commenting out this call leaves ordinary testing unchanged; importing
DispatchCheckup alone does not load DispatchDoctor or change the environment.

# Example
```julia
import DispatchCheckup
DispatchCheckup.dispatch_doctor(:MyPackage; unstable=(:foo, :bar))
using Test, MyPackage
```
"""
function dispatch_doctor(package::Symbol; unstable=(), kwargs...)
    implementation = _implementation()
    entrypoint = Base.invokelatest(getglobal, implementation, :dispatch_doctor)
    return Base.invokelatest(entrypoint, package; unstable, kwargs...)
end

"""
    source_root(package::Module)

Return the original package source directory during an instrumented run, or
`pkgdir(package)` during ordinary testing. Source-analysis guards can use this
to match original method locations without treating the temporary overlay as
the package's source checkout. This query does not activate instrumentation.
"""
function source_root(package::Module)
    if Base.invokelatest(isdefined, @__MODULE__, :Implementation)
        implementation = Base.invokelatest(getglobal, @__MODULE__, :Implementation)
        query = Base.invokelatest(getglobal, implementation, :original_source_root)
        return Base.invokelatest(query, package)
    end
    return pkgdir(package)
end

"""
    test_original(; test_args=String[], env=Pair[]) -> Bool

During a checked run, run the same test entrypoint in a fresh process using the
original resolved environment and package source. Pass the test suite's normal
selectors through `test_args` or additional string environment pairs through
`env`. A failing subprocess propagates its exit status. Successful runs return
`true` and are recorded in the instrumentation report.

During ordinary testing this returns `false` without loading the implementation,
so `test_original(test_args=["test_guards.jl"]) || include("test_guards.jl")`
checks production code in either mode. This does not resolve or install packages.
"""
function test_original(; test_args=String[], env=Pair[])
    Base.invokelatest(isdefined, @__MODULE__, :Implementation) || return false
    implementation = Base.invokelatest(getglobal, @__MODULE__, :Implementation)
    entrypoint = Base.invokelatest(getglobal, implementation, :test_original)
    return Base.invokelatest(entrypoint; test_args, env)
end

# These bridges are used only by generated launch/entry files. Keeping the
# implementation lazy also makes ordinary `import DispatchCheckup` inert.
function _child_main(config_file::String)
    implementation = _implementation()
    entrypoint = Base.invokelatest(getglobal, implementation, :child_main)
    return Base.invokelatest(entrypoint, config_file)
end

function _original_main(config_file::String)
    implementation = _implementation()
    entrypoint = Base.invokelatest(getglobal, implementation, :original_main)
    return Base.invokelatest(entrypoint, config_file)
end

function _instrument_entry(mod::Module, config_file::String, source::String)
    implementation = _implementation()
    entrypoint = Base.invokelatest(getglobal, implementation, :instrument_entry)
    return Base.invokelatest(entrypoint, mod, config_file, source)
end

end # module DispatchCheckup

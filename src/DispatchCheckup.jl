"""
DispatchCheckup runs a package's tests as if DispatchDoctor's `@stable` were applied to the
whole package, without changing the package's source. See [`dispatch_doctor`](@ref).
"""
module DispatchCheckup

import DispatchDoctor, TOML
using MacroTools: @capture, isdef, longdef1, postwalk, splitdef

public dispatch_doctor

include("transform.jl")
include("overlay.jl")

# The state of the (single) activation in this process.
struct Activation
    config::Config
    shims::Dict{Base.PkgId,String}              # the package and its extensions => shim
    triggers::Dict{Base.PkgId,Vector{Base.PkgId}}  # extension => packages that load it
    original::Vector{String}                    # guard files
    project::Union{Nothing,String}              # the state before activation, for the guards
    variables::Dict{String,Union{Nothing,String}}
    directory::String
    loaded::Set{Base.PkgId}                     # loaded from their shims
    failures::Vector{String}
end
const ACTIVE = Ref{Union{Nothing,Activation}}(nothing)
const SEPARATOR = Sys.iswindows() ? ';' : ':'

"""
    dispatch_doctor(pkg::Symbol; unstable = (), original = (), mode = "error", union_limit = 1)

Make the coming `using pkg` load the package with DispatchDoctor's `@stable` applied to all
of it, as if its whole module (with its submodules, included files and extensions) were
written inside `@stable`. Call it before the package is loaded, at the top of
`test/runtests.jl`; commenting out the call gives an ordinary run.

- `unstable`: definitions not to check, as with DispatchDoctor's `@unstable`. Each entry is
  `:foo` (every definition named `foo`), `Symbol("MyPackage.Sub.foo")` (the definitions of
  `foo` in that module of the package or of an extension, or written as `MyPackage.Sub.foo`),
  `Symbol("Base.getindex")` (the definitions written as `Base.getindex(...)`), or
  `:foo => "src/file.jl:LINE"` (the definition of `foo` starting at that line). Every entry
  must match a definition in the package's sources.
- `original`: test files (relative to the calling file) to run after the suite, in one
  fresh Julia process with the original, unchecked package.
- `mode`: DispatchDoctor's `default_mode`, `"error"` or `"warn"`.
- `union_limit`: DispatchDoctor's `default_union_limit`.

The run fails if the package or an extension is not loaded from the checked overlay, or if
the package never loads. Test files can tell a checked run by
`get(ENV, "DISPATCH_CHECKUP", "") == "checked"`.
"""
function dispatch_doctor(pkg::Symbol; unstable = (), original = (),
                         mode::AbstractString = "error", union_limit::Integer = 1)
    here = something(Base.source_path(nothing), joinpath(pwd(), "REPL"))
    guards = String[abspath(dirname(here), f) for f in
                    (original isa AbstractString ? (original,) : original)]
    return _activate(pkg, _exclusions(unstable), guards, String(mode), Int(union_limit))
end

function _activate(pkg::Symbol, exclusions::Vector{Exclusion}, guards::Vector{String},
                   mode::String, union_limit::Int)
    mode in ("error", "warn") ||
        throw(ArgumentError("mode must be \"error\" or \"warn\", not $(repr(mode))"))
    union_limit >= 1 || throw(ArgumentError("union_limit must be at least 1"))
    a = ACTIVE[]
    if a !== nothing  # (calling it again with the same options does nothing)
        (a.config.id.name, a.config.unstable, a.config.mode, a.config.union_limit, a.original) ==
            (String(pkg), exclusions, mode, union_limit, guards) && return nothing
        error("DispatchCheckup is already active for $(a.config.id.name), with other options")
    end
    _check_doctor()
    foreach(f -> isfile(f) || throw(ArgumentError("original= file $f does not exist")), guards)
    # A Julia process started by a checked run inherits its per-run environment: set it
    # aside, so that this process is checked (and runs its guards) as if started normally.
    inherited = pop!(ENV, "DISPATCH_CHECKUP_ENVIRONMENT", nothing)
    if inherited !== nothing
        filter!(!=(inherited), LOAD_PATH)
        rest = chopprefix(get(ENV, "JULIA_LOAD_PATH", ""), inherited * SEPARATOR)
        isempty(rest) ? delete!(ENV, "JULIA_LOAD_PATH") : (ENV["JULIA_LOAD_PATH"] = rest)
    end

    t = _locate(pkg)
    Base.root_module_exists(t.id) && error("DispatchCheckup: $pkg is already loaded; " *
                                           "call dispatch_doctor before `using $pkg`")
    cfg = Config((t.id, t.root, exclusions, mode, union_limit))
    _check_matches(t.root, [t.entry; collect(values(t.exts))], exclusions)  # check (3)
    overlay, shims = _write_overlay(t, cfg)
    environment = _write_environment(t, overlay, cfg)

    variables = Dict{String,Union{Nothing,String}}(
        k => get(ENV, k, nothing) for k in ("JULIA_LOAD_PATH", "JULIA_PROJECT", "JULIA_DEPOT_PATH"))
    project, directory = Base.active_project(), pwd()
    # Keep the active project, here and in the Julia processes started by the tests (when
    # it is the first project on LOAD_PATH, as under Pkg.test, the per-run one would be).
    if Base.ACTIVE_PROJECT[] === nothing && project !== nothing
        Base.set_active_project(project)
        get!(ENV, "JULIA_PROJECT", project)
    end
    pushfirst!(LOAD_PATH, environment)
    ENV["JULIA_LOAD_PATH"] = environment * SEPARATOR * something(variables["JULIA_LOAD_PATH"], "")
    ENV["DISPATCH_CHECKUP_ENVIRONMENT"] = environment
    ENV["DISPATCH_CHECKUP"] = "checked"

    _check_options(t.uuid, cfg)  # check (2), for the package that is not loaded yet

    CONFIG[] = cfg
    ACTIVE[] = Activation(cfg, shims, t.triggers, guards, project, variables, directory,
                          Set{Base.PkgId}(), String[])
    push!(Base.package_callbacks, _check_loaded)
    atexit(_finish)
    return nothing
end

# The DispatchDoctor that is loaded must be the fork from DispatchCheckup's [sources].
function _check_doctor()
    isdefined(DispatchDoctor, :DISPATCHCHECKUP_PATCHLEVEL) &&
        DispatchDoctor.DISPATCHCHECKUP_PATCHLEVEL >= 3 ||
        error("DispatchCheckup needs the DispatchDoctor fork named in its [sources], " *
              "not $(pathof(DispatchDoctor))")
    DispatchDoctor.JULIA_OK || error("DispatchDoctor is disabled on Julia $VERSION")
    return nothing
end

# Check (1): the package (or an extension) was loaded from its shim in the overlay.
function _check_loaded(pkg::Base.PkgId)
    a = ACTIVE[]
    (a === nothing || !haskey(a.shims, pkg)) && return
    from = @lock Base.require_lock get(LOADED_FROM, pkg, Base.pkgorigins[pkg].path)
    if from == a.shims[pkg]
        push!(a.loaded, pkg)
    else
        push!(a.failures, "$(pkg.name) was loaded from $from instead of the overlay " *
                          "$(a.shims[pkg]), so it was not checked")
        printstyled(stderr, "DispatchCheckup: ", a.failures[end], "\n"; color = :red, bold = true)
    end
    return nothing
end

# At exit: fail if a check failed, then run the guard files. The exit status is the first
# nonzero one of the suite, the checks and the guards.
function _finish(code::Integer)
    a = ACTIVE[]
    a === nothing && return
    status = code
    if !(a.config.id in a.loaded)
        isempty(a.failures) &&
            push!(a.failures, "$(a.config.id.name) was never loaded, so nothing was checked")
    else  # an extension must have loaded once its packages did (Base only logs a failure)
        for (ext, packages) in a.triggers
            Base.root_module_exists(ext) || !all(Base.root_module_exists, packages) ||
                push!(a.failures, "the extension $(ext.name) did not load, so it was not checked")
        end
    end
    for failure in a.failures
        printstyled(stderr, "DispatchCheckup: ", failure, "\n"; color = :red, bold = true)
    end
    isempty(a.failures) || status != 0 || (status = 1)
    if code < 128 && !isempty(a.original)  # (not when killed by a signal)
        guards = _run_original(a)
        status == 0 && (status = guards)
    end
    status == code || exit(status)
    return nothing
end

# Run the guard files in one fresh, ordinary Julia process, as before activation.
function _run_original(a::Activation)
    code = """
        module DispatchCheckupOriginal
        const Test = Base.require(Base.PkgId(Base.UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40"), "Test"))
        Test.@testset "DispatchCheckup original=" begin
            for file in $(repr(a.original))
                Test.@testset "\$file" begin
                    Base.include(Main, file)
                end
            end
        end
        end
        """
    environment = filter(p -> !startswith(first(p), "DISPATCH_CHECKUP"), copy(ENV))
    for (k, v) in a.variables
        v === nothing ? delete!(environment, k) : (environment[k] = v)
    end
    threads = "--threads=$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))"
    project = a.project === nothing ? String[] : ["--project=$(a.project)"]
    command = `$(Base.julia_cmd()) $threads $project -e $code`
    flush(stdout), flush(stderr)
    process = run(ignorestatus(setenv(command, environment; dir = a.directory)))
    return process.termsignal != 0 ? 128 + Int(process.termsignal) : Int(process.exitcode)
end

# Compile the activation path into the package image (it takes seconds otherwise).
precompile(_activate, (Symbol, Vector{Exclusion}, Vector{String}, String, Int))
precompile(_check_loaded, (Base.PkgId,))
precompile(_finish, (Int32,))
ccall(:jl_generating_output, Cint, ()) == 1 &&  # (scanning our own sources)
    _check_matches(@__DIR__, [joinpath(@__DIR__, "DispatchCheckup.jl")], Exclusion[])

end # module DispatchCheckup

# Helpers for tests that run generated fixture packages in fresh Julia processes.
module Fixtures

import DispatchCheckup
const TOML = DispatchCheckup.TOML

const CHECKUP = pkgdir(DispatchCheckup)
# The registered DispatchDoctor; the fork has its own UUID ("DispatchDoctor" here).
const REGISTERED_DOCTOR = "8d63f2c5-f18a-4cf2-ba9d-b3f60fc568c8"
const FORK = TOML.parsefile(joinpath(CHECKUP, "Project.toml"))["deps"]["DispatchDoctor"]
const UUIDS = Dict("DispatchCheckup" => "ca055ede-32eb-4961-937e-82d9c5ec6430",
                   "DispatchDoctor" => FORK,
                   "Test" => "8dfed614-e22c-5e08-85e1-65c5234f0b40",
                   "Dates" => "ade2ca70-3891-5945-98fb-dc099432e06a",
                   "Unicode" => "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5",
                   "DCFixture" => "eadb23ac-f16a-4969-a7d5-a895e9f8275b",
                   "DCBare" => "0fe9d090-7ca4-44c6-8024-89ad1aa4c999",
                   "DCLayoutA" => "a17f895a-3e09-4af6-8a93-4f47cf707c98",
                   "DCLayoutB" => "f8f70f52-2994-4354-964a-a746e2b4b7d0",
                   "DCFixtureGPU" => "6689c958-80c0-4aa5-a751-21295d56c2ee",
                   "DCUsesDoctor" => "0f021db6-fcf7-4914-a5c7-94b770dab57c",
                   "DCAllowUnstable" => "710ae0fb-4f09-48f0-9a9f-d98297e6d158",
                   "CUDA" => "052768ef-5323-5732-b1bb-66c8b64840ba")

function write_files(root::String, files)
    for (path, content) in files
        mkpath(dirname(joinpath(root, path)))
        write(joinpath(root, path), content isa AbstractDict ? sprint(TOML.print, content) : content)
    end
    return root
end

package_project(name; kws...) = Dict{String,Any}("name" => name, "uuid" => UUIDS[name],
                                                 "version" => "0.1.0", (String(k) => v for (k, v) in kws)...)

# A package that uses the registered DispatchDoctor, which DispatchCheckup must leave to it.
const USES_DOCTOR = Dict(
    "Project.toml" => package_project("DCUsesDoctor"; deps = Dict("DispatchDoctor" => REGISTERED_DOCTOR),
                                      compat = Dict("DispatchDoctor" => "0.4.29")),
    "src/DCUsesDoctor.jl" => """
        module DCUsesDoctor
        import DispatchDoctor
        # Registered DispatchDoctor 0.4.29 takes this call for unstable; the fork does not.
        DispatchDoctor.@stable typed_kw(x; T = Float64) = T(x)
        plain_unstable(x) = x > 0 ? x : 0.0
        end
        """)

# Run `julia args...` in `dir` with a clean load path; return the exit code and output.
function julia(args...; dir::String, env = Dict{String,String}(), timeout = 1200)
    variables = filter(p -> !startswith(first(p), "DISPATCH_CHECKUP") &&
                            first(p) ∉ ("JULIA_PROJECT", "JULIA_LOAD_PATH"), copy(ENV))
    merge!(variables, Dict("JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_PKG_PRECOMPILE_AUTO" => "0"), env)
    log = tempname()
    command = setenv(`$(Base.julia_cmd()) --startup-file=no $(collect(args))`, variables; dir)
    process = open(io -> run(pipeline(ignorestatus(command); stdout = io, stderr = io); wait = false),
                   log, "w")
    if timedwait(() -> process_exited(process), timeout) === :timed_out
        kill(process)
        error("fixture process timed out:\n", read(log, String))
    end
    output = read(log, String)
    rm(log)
    return (; code = process.exitcode, output)
end

# A depot path with a depot of its own (`dir`) first. What the Julia processes that get it
# compile, and the overlays they write, stay in it, so checked runs of one package whose
# options differ but whose preferences are the same, which would otherwise take turns writing
# one package-image file, run side by side.
depot_path(dir::String) = join([mkpath(dir); DEPOT_PATH], Sys.iswindows() ? ';' : ':')

# Resolve `project` (a directory) with Pkg, in a separate process.
function resolve(project::String; code = "Pkg.resolve()")
    result = julia("--project=$project", "-e", "using Pkg; $code"; dir = project)
    result.code == 0 || error("could not resolve $project:\n", result.output)
    return project
end

# Hashes of all files under `root`, to check that nothing changed them.
snapshot(root) = Dict(relpath(joinpath(d, f), root) => hash(read(joinpath(d, f)))
                      for (d, _, fs) in walkdir(root) for f in fs)

# Remove the overlays that DispatchCheckup made for the package `name` (one per configuration).
function remove_overlays(name)
    overlays = joinpath(first(DEPOT_PATH), "scratchspaces", UUIDS["DispatchCheckup"], "overlays")
    for dir in (isdir(overlays) ? readdir(overlays; join = true) : String[])
        startswith(basename(dir), "$name-") && rm(dir; recursive = true, force = true)
    end
end

end # module Fixtures

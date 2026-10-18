module DispatchCheckupFixtures

using Pkg, TOML, SHA
import DispatchCheckup

const CHECKUP_ROOT = pkgdir(DispatchCheckup)
const TEMPLATE_ROOT = @__DIR__
const FIXTURE_UUIDS = Dict(
    "DCFixtureDependency" => "a17f895a-3e09-4af6-8a93-4f47cf707c98",
    "DCFixtureTarget" => "eadb23ac-f16a-4969-a7d5-a895e9f8275b",
    "DCFixtureConsumer" => "f8f70f52-2994-4354-964a-a746e2b4b7d0",
    "DCFixtureSkipped" => "0fe9d090-7ca4-44c6-8024-89ad1aa4c999",
    "DCFixtureGPU" => "6689c958-80c0-4aa5-a751-21295d56c2ee",
)

struct Sandbox
    root::String
    environment::String
    target::String
    packages::Dict{String,String}
end

function write_toml(path, value)
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, value; sorted=true)
    end
    return path
end

function capture(sandbox::Sandbox, label::String, command::Cmd;
                 extra_env=Dict{String,String}(), timeout=180.0)
    log = joinpath(sandbox.root, "logs", label * ".log")
    mkpath(dirname(log))
    environment = merge(Dict{String,String}(ENV), Dict(
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        "JULIA_NUM_PRECOMPILE_TASKS" => "1",
        "DCT_SENTINEL" => "spaces and unicode λ preserved",
        "DCT_ORIGINAL_TARGET" => sandbox.target,
        "DCT_EXPECTED_CWD" => sandbox.root,
    ), extra_env)
    command = setenv(Cmd(command; dir=sandbox.root, detach=Sys.isunix()), environment)
    process = open(log, "w") do io
        run(pipeline(ignorestatus(command); stdout=io, stderr=io); wait=false)
    end
    if timedwait(() -> process_exited(process), timeout; pollint=0.1) == :timed_out
        # The process has its own group on Unix, including any relaunched child.
        if Sys.isunix()
            ccall(:kill, Cint, (Cint, Cint), -getpid(process), Base.SIGKILL)
        else
            kill(process, Base.SIGKILL)
        end
        wait(process)
        error("fixture $label exceeded $timeout seconds\n", read(log, String))
    end
    wait(process)
    output = read(log, String)
    persistent_logs = get(ENV, "DISPATCHCHECKUP_TEST_LOG_DIR", "")
    if !isempty(persistent_logs)
        mkpath(persistent_logs)
        destination = joinpath(persistent_logs, basename(sandbox.root) * "-" * label * ".log")
        cp(log, destination; force=true)
        log = destination
    end
    return (; code=process.exitcode, output, log)
end

function with_sandbox(f::F; gpu::Bool=false) where {F}
    mktempdir(; prefix="dispatchcheckup-fixtures-") do root
        packages = Dict{String,String}()
        folders = gpu ? ("Dependency", "Target", "Consumer", "Skipped", "GPU") :
                        ("Dependency", "Target", "Consumer", "Skipped")
        for folder in folders
            destination = joinpath(root, folder)
            cp(joinpath(TEMPLATE_ROOT, folder), destination)
            metadata = TOML.parsefile(joinpath(destination, "Project.toml"))
            packages[metadata["name"]] = destination
        end
        target = packages["DCFixtureTarget"]
        # Committed fixtures use the public URL. Only this generated test resolver
        # points at the package checkout that the outer Pkg.test is testing.
        target_project = TOML.parsefile(joinpath(target, "Project.toml"))
        target_project["sources"]["DispatchCheckup"] = Dict("path" => CHECKUP_ROOT)
        write_toml(joinpath(target, "Project.toml"), target_project)

        environment = joinpath(root, "environment")
        dependencies = Dict(
            "DispatchCheckup" => "ca055ede-32eb-4961-937e-82d9c5ec6430",
            "Test" => "8dfed614-e22c-5e08-85e1-65c5234f0b40",
            "Dates" => "ade2ca70-3891-5945-98fb-dc099432e06a",
        )
        sources = Dict{String,Any}("DispatchCheckup" => Dict("path" => CHECKUP_ROOT))
        for (name, path) in packages
            dependencies[name] = FIXTURE_UUIDS[name]
            sources[name] = Dict("path" => path)
        end
        gpu && (dependencies["CUDA"] = "052768ef-5323-5732-b1bb-66c8b64840ba")
        write_toml(joinpath(environment, "Project.toml"),
                   Dict("deps" => dependencies, "sources" => sources))
        preferences = Dict("DCFixtureTarget" => Dict(
            "dispatch_doctor_mode" => "disable",
            "dispatch_doctor_union_limit" => 99,
        ))
        for project in (environment, target)
            write_toml(joinpath(project, "LocalPreferences.toml"), preferences)
        end
        sandbox = Sandbox(root, environment, target, packages)
        code = "using Pkg; Pkg.resolve(); Pkg.activate(" * repr(target) * "); Pkg.resolve()"
        result = capture(sandbox, "resolve", `$(Base.julia_cmd()) --startup-file=no --project=$environment -e $code`;
                         timeout=300.0)
        result.code == 0 || error("fixture environment failed to resolve\n", result.output)
        return f(sandbox)
    end
end

function driver(body::String; target::Symbol=:DCFixtureTarget, active::Bool=true,
                unstable=(), repeat::Bool=false, require_all::Bool=false,
                entrypoint=nothing, report=nothing)
    call = "DispatchCheckup.dispatch_doctor(" * repr(target) *
           "; unstable=" * repr(unstable) * (require_all ? ", require_all=true" : "") *
           (entrypoint === nothing ? "" : ", entrypoint=" * repr(entrypoint)) *
           (report === nothing ? "" : ", report=" * repr(report)) * ")"
    activation = active ? call : "# " * call
    repeated = repeat ? call : ""
    off_checks = active ? "" : """
        @assert !fixture_loaded("DispatchDoctor")
        @assert Base.active_project() == fixture_original_project
        @assert LOAD_PATH == fixture_original_load_path
        @assert DEPOT_PATH == fixture_original_depot_path
        @assert Dict(ENV) == fixture_original_environment
        """
    return """
        fixture_loaded(name) = any(id -> id.name == name, keys(Base.loaded_modules))
        const fixture_original_project = Base.active_project()
        const fixture_original_load_path = copy(LOAD_PATH)
        const fixture_original_depot_path = copy(DEPOT_PATH)
        const fixture_original_environment = Dict(ENV)
        @assert !fixture_loaded($(repr(string(target))))
        println("DCT_ENTRY_FLAGS=", Threads.nthreads(:default), ",",
                Base.JLOptions().check_bounds, ",", Base.JLOptions().depwarn)
        isempty(PROGRAM_FILE) && println("DCT_EMPTY_PROGRAM_FILE_ENTRY")
        import DispatchCheckup
        $off_checks
        $activation
        $repeated
        @assert !fixture_loaded($(repr(string(target))))
        $off_checks
        println("DCT_ACTIVE_PROJECT=", Base.active_project())
        $body
        println("DCT_BODY_COMPLETE")
        """
end

function run_script(sandbox, label, body; args=String[], extra_env=Dict{String,String}(), kwargs...)
    script = joinpath(sandbox.root, label * ".jl")
    write(script, driver(body; kwargs...))
    before = original_fingerprints(sandbox)
    result = capture(sandbox, label,
        `$(Base.julia_cmd()) --startup-file=no --depwarn=error --project=$(sandbox.environment) $script $args`;
        extra_env)
    return (; result..., originals_unchanged=before == original_fingerprints(sandbox))
end

function run_pkg_test(sandbox, label, body; args=String[], extra_env=Dict{String,String}(), kwargs...)
    script = joinpath(sandbox.target, "test", "runtests.jl")
    mkpath(dirname(script))
    write(script, driver(body; kwargs...))
    code = "using Pkg; Pkg.test(; test_args=" * repr(args) * ")"
    before = original_fingerprints(sandbox)
    process_environment = merge(Dict("DCT_EXPECTED_CWD" => joinpath(sandbox.target, "test")), extra_env)
    result = capture(sandbox, label,
        `$(Base.julia_cmd()) --startup-file=no --depwarn=error --project=$(sandbox.target) -e $code`;
        extra_env=process_environment, timeout=300.0)
    return (; result..., originals_unchanged=before == original_fingerprints(sandbox))
end

function fingerprints(paths)
    found = Dict{String,String}()
    for path in paths
        isdir(path) || continue
        for (directory, _, files) in walkdir(path), file in files
            full = joinpath(directory, file)
            found[full] = bytes2hex(sha256(read(full)))
        end
    end
    return found
end

original_fingerprints(sandbox) = fingerprints([sandbox.environment; collect(values(sandbox.packages))])

function target_cache_fingerprints()
    version = "v$(VERSION.major).$(VERSION.minor)"
    return fingerprints([joinpath(depot, "compiled", version, name)
        for depot in DEPOT_PATH for name in ("DCFixtureTarget", "DCFixtureTargetDatesExt")])
end

function printed_paths(result, key)
    prefix = key * "="
    return [strip(line[length(prefix)+1:end]) for line in split(result.output, '\n') if startswith(line, prefix)]
end

end

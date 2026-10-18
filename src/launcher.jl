const CHILD_CONFIG_ENV = "DISPATCH_CHECKUP_CHILD_CONFIG"
const CHILD_TOKEN_ENV = "DISPATCH_CHECKUP_CHILD_TOKEN"
const CHILD_DIGEST_ENV = "DISPATCH_CHECKUP_CHILD_DIGEST"

struct ChildActivation
    config_file::String
    token::String
    pid::Int
end

const _CHILD_ACTIVATION = Ref{Union{Nothing,ChildActivation}}(nothing)
const _ORIGINAL_TESTS = Dict{String,Vector{Dict{String,Any}}}()
const _ORIGINAL_TESTS_LOCK = ReentrantLock()

_same_project(left::String, right::String) =
    isfile(left) && isfile(right) ? realpath(left) == realpath(right) : abspath(left) == abspath(right)

function _normalize_exclusions(unstable)
    unstable isa Tuple && all(item -> item isa Symbol, unstable) ||
        throw(ArgumentError("unstable must be a tuple of function-name Symbols, such as (:foo, :bar)"))
    return sort!(unique!(String[string(item) for item in unstable]))
end

function _entry_candidates()
    files = String[]
    helper_sources = normpath(@__DIR__)
    julia_root = normpath(dirname(Sys.BINDIR))
    for frame in stacktrace()
        file = String(frame.file)
        file in ("none", "", "REPL") && continue
        path = abspath(file)
        isfile(path) || continue
        startswith(path, helper_sources * Base.Filesystem.path_separator) && continue
        startswith(path, julia_root * Base.Filesystem.path_separator) && continue
        push!(files, path)
    end
    return unique(files)
end

function _test_entry(entrypoint::Union{Nothing,AbstractString})
    if entrypoint !== nothing
        file = abspath(entrypoint)
        isfile(file) || throw(ArgumentError("test entrypoint does not exist: $file"))
        return file
    end
    if !isempty(PROGRAM_FILE)
        file = abspath(PROGRAM_FILE)
        isfile(file) && return file
    end
    candidates = _entry_candidates()
    isempty(candidates) && throw(ArgumentError(
        "cannot discover a file-based test entrypoint; pass entrypoint=\"path/to/runtests.jl\" " *
        "when invoking DispatchCheckup from an interactive or -e driver"))
    return last(candidates)
end

function _child_requested()
    return any(name -> haskey(ENV, name), (CHILD_CONFIG_ENV, CHILD_TOKEN_ENV, CHILD_DIGEST_ENV))
end

function _validated_child_config(config_file::String; check_launch_state::Bool=true)
    for name in (CHILD_CONFIG_ENV, CHILD_TOKEN_ENV, CHILD_DIGEST_ENV)
        haskey(ENV, name) || error("incomplete DispatchCheckup child marker: missing $name")
    end
    abspath(ENV[CHILD_CONFIG_ENV]) == abspath(config_file) ||
        error("DispatchCheckup child configuration path does not match its launcher")
    isfile(config_file) && !islink(config_file) || error("DispatchCheckup child configuration is missing or not a regular file")
    bytes2hex(open(SHA.sha256, config_file)) == ENV[CHILD_DIGEST_ENV] ||
        error("DispatchCheckup child configuration digest does not match its launcher")
    config = TOML.parsefile(config_file)
    get(config, "format_version", 0) == 1 || error("unsupported DispatchCheckup child configuration")
    config["token"] == ENV[CHILD_TOKEN_ENV] || error("DispatchCheckup child token does not match its launcher")
    kind = get(config, "run_kind", "checked")
    kind in ("checked", "original") || error("unsupported DispatchCheckup controller kind")
    if check_launch_state
        active = Base.active_project()
        active !== nothing && _same_project(active, config["project_file"]) ||
            error("DispatchCheckup child is not using its isolated project")
        pwd() == config["working_directory"] || error("DispatchCheckup child working directory changed before activation")
        ARGS == config["arguments"] || error("DispatchCheckup child arguments changed before activation")
    end
    isfile(config["test_entry"]) && bytes2hex(open(SHA.sha256, config["test_entry"])) == config["test_entry_digest"] ||
        error("DispatchCheckup test entrypoint changed after the launch snapshot")
    _source_fingerprint(config["snapshot_root"]) == config["snapshot_digest"] ||
        error("DispatchCheckup source snapshot changed after the launch snapshot")
    _source_fingerprint(config["overlay_root"]) == config["overlay_digest"] ||
        error("DispatchCheckup package overlay changed after the launch snapshot")
    _source_fingerprint(config["helper_overlay_root"]) == config["helper_overlay_digest"] ||
        error("DispatchCheckup helper overlay changed after the launch snapshot")
    if kind == "original"
        _original_source_fingerprint(config["original_root"], config["snapshot_root"]) == config["original_source_digest"] ||
            error("DispatchCheckup original package source changed after activation")
        for (file, digest) in config["original_environment_files"]
            isfile(file) && bytes2hex(open(SHA.sha256, file)) == digest ||
                error("DispatchCheckup original resolved environment changed: $file")
        end
        if check_launch_state
            LOAD_PATH == config["original_load_path"] ||
                error("DispatchCheckup original load path changed before activation")
            DEPOT_PATH == config["original_depot_path"] ||
                error("DispatchCheckup original depot path changed before activation")
        end
    end
    helper = get(Base.loaded_modules, Base.PkgId(CHECKUP_UUID, "DispatchCheckup"), nothing)
    helper !== nothing && realpath(pathof(helper)) == realpath(config["helper_entry"]) ||
        error("DispatchCheckup child loaded an unisolated helper package")
    id = Base.PkgId(UUIDs.UUID(config["target_uuid"]), config["target_name"])
    expected = kind == "original" ? config["main_entry"] :
        joinpath(config["overlay_root"], relpath(config["main_entry"], config["original_root"]))
    if check_launch_state
        found = Base.locate_package(id)
        found !== nothing && realpath(found) == realpath(expected) ||
            error("DispatchCheckup target does not resolve to its instrumented overlay")
    end
    if haskey(Base.loaded_modules, id)
        loaded = Base.loaded_modules[id]
        Base.PkgId(loaded) == id || error("DispatchCheckup loaded target has the wrong package identity")
        source = pathof(loaded)
        source !== nothing && realpath(source) == realpath(expected) ||
            error("DispatchCheckup target was loaded from an uninstrumented source")
    end
    return config
end

function _active_controller(config_file::String, config::Dict{String,Any})
    activation = _CHILD_ACTIVATION[]
    activation !== nothing && activation.pid == getpid() &&
        activation.config_file == abspath(config_file) && activation.token == config["token"] ||
        error("DispatchCheckup child marker was inherited without its isolated test controller")
    return activation
end

function _child_activation(name::Symbol, exclusions::Vector{String}; require_all::Bool,
                           entrypoint::Union{Nothing,AbstractString}, report::Union{Nothing,AbstractString})
    config_file = get(ENV, CHILD_CONFIG_ENV, "")
    isempty(config_file) && error("DispatchCheckup child marker has no configuration path")
    config = _validated_child_config(config_file)
    _active_controller(config_file, config)
    config["target_name"] == String(name) || error("DispatchCheckup child was configured for a different package")
    config["unstable"] == exclusions || error("DispatchCheckup child exclusions do not match the activation request")
    config["require_all"] == require_all || error("DispatchCheckup child coverage policy does not match the activation request")
    entrypoint === nothing || abspath(entrypoint) == config["test_entry"] ||
        error("DispatchCheckup child entrypoint does not match the activation request")
    report === nothing || abspath(report) == get(config, "report_destination", "") ||
        error("DispatchCheckup child report path does not match the activation request")
    return nothing
end

function _original_options(test_args, env)
    all(arg -> arg isa AbstractString, test_args) ||
        throw(ArgumentError("test_args must contain strings"))
    arguments = String[String(arg) for arg in test_args]
    overrides = Dict{String,String}()
    for pair in env
        pair isa Pair && first(pair) isa AbstractString && last(pair) isa AbstractString ||
            throw(ArgumentError("env must contain string environment pairs"))
        name, value = String(first(pair)), String(last(pair))
        (startswith(name, "DISPATCH_CHECKUP_") ||
         name in ("JULIA_PROJECT", "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH")) &&
            throw(ArgumentError("test_original cannot override controller environment variable $name"))
        overrides[name] = value
    end
    return arguments, overrides
end

function _original_command(config::Dict{String,Any}, config_file::String, overrides::Dict{String,String})
    threads = join(config["original_threads"], ',')
    arguments = String["--startup-file=no", "--history-file=no",
        "--project=$(config["project_file"])", "--threads=$threads", config["bootstrap_file"]]
    append!(arguments, config["arguments"])
    command = Cmd(Cmd(vcat(String.(config["original_julia_command"]), arguments)); dir=config["working_directory"])
    environment = Dict{String,String}(ENV)
    merge!(environment, overrides)
    separator = Sys.iswindows() ? ';' : ':'
    environment["JULIA_PROJECT"] = config["project_file"]
    environment["JULIA_LOAD_PATH"] = join(config["original_load_path"], separator)
    environment["JULIA_DEPOT_PATH"] = join(config["original_depot_path"], separator)
    environment[CHILD_CONFIG_ENV] = config_file
    environment[CHILD_TOKEN_ENV] = config["token"]
    environment[CHILD_DIGEST_ENV] = bytes2hex(open(SHA.sha256, config_file))
    return setenv(command, environment)
end

function test_original(; test_args=String[], env=Pair[])
    activation = _CHILD_ACTIVATION[]
    activation === nothing && !_child_requested() && return false
    config_file = get(ENV, CHILD_CONFIG_ENV, "")
    isempty(config_file) && error("DispatchCheckup child marker has no configuration path")
    config = _validated_child_config(config_file; check_launch_state=false)
    _active_controller(config_file, config)
    get(config, "run_kind", "checked") == "original" && return false
    arguments, overrides = _original_options(test_args, env)
    # Guard-only selectors may delegate before importing their target. Loading
    # it here retains the normal loader/canary/coverage validation in this run.
    id = Base.PkgId(UUIDs.UUID(config["target_uuid"]), config["target_name"])
    Base.require(id)
    _validated_child_config(config_file; check_launch_state=false)
    root = mktempdir(dirname(config_file); prefix="original-")
    original = deepcopy(config)
    original["run_kind"] = "original"
    original["token"] = string(UUIDs.uuid4())
    original["project_file"] = config["original_project_file"]
    original["helper_entry"] = config["original_helper_entry"]
    original["arguments"] = arguments
    original["bootstrap_file"] = joinpath(root, "launch.jl")
    original["report_file"] = joinpath(root, "result.toml")
    ordinary_config = joinpath(root, "config.toml")
    _write_toml(ordinary_config, original)
    write(original["bootstrap_file"], "import DispatchCheckup\n" *
        "DispatchCheckup._original_main($(repr(ordinary_config)))\n")
    record = Dict{String,Any}("test_entry" => config["test_entry"], "test_args" => arguments,
        "env" => overrides, "project_file" => original["project_file"],
        "target_entry" => config["main_entry"], "source_digest" => config["original_source_digest"])
    status = 1
    process = nothing
    try
        @info "DispatchCheckup original-source test run" package=config["target_name"] test_args=arguments env=overrides
        command = pipeline(ignorestatus(_original_command(original, ordinary_config, overrides));
                           stdin=stdin, stdout=stdout, stderr=stderr)
        process = run(command; wait=false)
        wait(process)
        status = _exit_status(process)
        record["exit_code"] = status
        if isfile(original["report_file"])
            result = TOML.parsefile(original["report_file"])
            record["validation_status"] = result["validation_status"]
            haskey(result, "validation_error") && (record["validation_error"] = result["validation_error"])
        else
            record["validation_status"] = "missing"
        end
        if status == 0 && record["validation_status"] != "passed"
            record["exit_code"] = status = 1
        end
        lock(_ORIGINAL_TESTS_LOCK) do
            push!(get!(() -> Dict{String,Any}[], _ORIGINAL_TESTS, config_file), record)
        end
    finally
        if process !== nothing && process_running(process)
            kill(process, Base.SIGKILL)
            wait(process)
        end
        rm(root; recursive=true, force=true)
    end
    status == 0 || exit(status)
    return true
end

function _finish_original(config_file::String; validate::Bool=true)
    config = TOML.parsefile(config_file)
    if !validate && isfile(config["report_file"]) &&
       get(TOML.parsefile(config["report_file"]), "validation_status", "") == "failed"
        return nothing
    end
    result = Dict{String,Any}("validation_status" => validate ? "passed" : "not_checked")
    try
        if validate
            _validated_child_config(config_file; check_launch_state=false)
            id = Base.PkgId(UUIDs.UUID(config["target_uuid"]), config["target_name"])
            haskey(Base.loaded_modules, id) || error("original test run never loaded its target package")
        end
    catch exception
        result["validation_status"] = "failed"
        result["validation_error"] = sprint(showerror, exception)
        rethrow()
    finally
        _write_toml(config["report_file"], result)
    end
    return nothing
end

function original_main(config_file::String)
    config = _validated_child_config(config_file)
    get(config, "run_kind", "checked") == "original" || error("expected an original-source controller")
    abspath(PROGRAM_FILE) == config["bootstrap_file"] ||
        error("original-source tests must start through their private controller")
    _CHILD_ACTIVATION[] === nothing || error("DispatchCheckup original controller cannot run twice")
    _CHILD_ACTIVATION[] = ChildActivation(abspath(config_file), config["token"], getpid())
    finished = Ref(false)
    atexit() do code
        finished[] && return
        finished[] = true
        try
            _finish_original(config_file; validate=code == 0)
        catch exception
            showerror(stderr, exception, catch_backtrace())
            println(stderr)
            code == 0 && exit(1)
        end
    end
    Core.eval(Base, :(PROGRAM_FILE = $(config["program_file"])))
    Base.include(Main, config["test_entry"])
    _finish_original(config_file)
    finished[] = true
    return nothing
end

function _child_command(environment::OverlayEnvironment)
    default_threads = Threads.nthreads(:default)
    interactive_threads = Threads.nthreads(:interactive)
    arguments = String["--startup-file=no", "--history-file=no",
                       "--project=$(environment.project_file)", "--compiled-modules=existing",
                       "--threads=$default_threads,$interactive_threads", environment.bootstrap_file]
    append!(arguments, ARGS)
    command = Cmd(Cmd(vcat(Base.julia_cmd().exec, arguments)); dir=pwd())
    config = TOML.parsefile(environment.config_file)
    separator = Sys.iswindows() ? ';' : ':'
    return addenv(command,
        CHILD_CONFIG_ENV => environment.config_file,
        CHILD_TOKEN_ENV => environment.token,
        CHILD_DIGEST_ENV => environment.digest,
        "JULIA_PROJECT" => environment.project_file,
        "JULIA_LOAD_PATH" => join(config["load_path"], separator),
        "JULIA_DEPOT_PATH" => join([environment.depot; DEPOT_PATH], separator),
        "JULIA_PKG_PRECOMPILE_AUTO" => "0")
end

function _exit_status(process::Base.Process)
    process.termsignal != 0 && return 128 + Int(process.termsignal)
    return process.exitcode < 0 ? 1 : Int(process.exitcode)
end

function _retain_report(environment::OverlayEnvironment)
    config = TOML.parsefile(environment.config_file)
    destination = get(config, "report_destination", nothing)
    if destination !== nothing && isfile(config["report_file"])
        mkpath(dirname(destination))
        cp(config["report_file"], destination; force=true)
    end
    return nothing
end

function dispatch_doctor(name::Symbol; unstable=(), require_all::Bool=false,
                         entrypoint::Union{Nothing,AbstractString}=nothing,
                         report::Union{Nothing,AbstractString}=nothing)
    VERSION >= v"1.13" || throw(ArgumentError("DispatchCheckup's isolated loader requires Julia 1.13 or newer"))
    DispatchDoctor.JULIA_OK || error("DispatchDoctor is disabled on Julia $VERSION; refusing an unchecked run")
    exclusions = _normalize_exclusions(unstable)
    if _child_requested()
        return _child_activation(name, exclusions; require_all, entrypoint, report)
    end
    target = _locate_target(name)
    haskey(Base.loaded_modules, target.id) && throw(ArgumentError(
        "$name is already loaded; call DispatchCheckup.dispatch_doctor before importing the package"))
    entry = _test_entry(entrypoint)
    destination = report === nothing ? nothing : abspath(report)
    environment = _build_environment(target, entry, exclusions; require_all, report=destination)
    status = 1
    process = nothing
    try
        @info "DispatchCheckup isolated test run" package=String(name) project=environment.project_file
        command = pipeline(ignorestatus(_child_command(environment)); stdin=stdin, stdout=stdout, stderr=stderr)
        process = run(command; wait=false)
        wait(process)
        status = _exit_status(process)
        if status == 0
            _retain_report(environment)
        else
            try
                _retain_report(environment)
            catch exception
                @warn "Could not retain DispatchCheckup's failure report" exception=(exception, catch_backtrace())
            end
        end
    finally
        if process !== nothing && process_running(process)
            kill(process, Base.SIGKILL)
            wait(process)
        end
        rm(environment.root; recursive=true, force=true)
    end
    # Continuing here would execute the suite a second time in the original
    # process, with the original package. Handoff always terminates the parent.
    exit(status)
end

function _write_child_report(config_file::String, config::Dict{String,Any}, validation_status::String;
                             validation_error=nothing)
    report = instrumentation_report(config_file)
    report["julia_version"] = string(VERSION)
    report["dispatch_doctor_version"] = string(pkgversion(DispatchDoctor))
    report["target_uuid"] = config["target_uuid"]
    report["target_name"] = config["target_name"]
    report["helper_provenance"] = config["helper_provenance"]
    report["target_provenance"] = config["target_provenance"]
    report["doctor_provenance"] = config["doctor_provenance"]
    report["validation_status"] = validation_status
    lock(_ORIGINAL_TESTS_LOCK) do
        report["original_tests"] = deepcopy(get(_ORIGINAL_TESTS, config_file, Dict{String,Any}[]))
    end
    validation_error === nothing || (report["validation_error"] = sprint(showerror, validation_error))
    _write_toml(config["report_file"], report)
    @info "DispatchCheckup instrumentation report" package=config["target_name"] counts=get(report, "counts", Dict())
    for record in get(report, "records", Any[])
        get(record, "kind", "") == "unsupported" || continue
        println(stderr, "DispatchCheckup unsupported: ", get(record, "name", ""),
                " at ", get(record, "file", ""), ":", get(record, "line", 0),
                " — ", get(record, "reason", ""))
    end
    return nothing
end

function _finish_child(config_file::String; validate::Bool=true)
    config = TOML.parsefile(config_file)
    if validate
        try
            _validated_child_config(config_file; check_launch_state=false)
            validate_instrumentation!(config_file)
            validate_exclusions!(config_file)
        catch exception
            # This path also runs inside atexit after explicit exit(0). Retain
            # the rejection report before changing that successful exit status.
            try
                _write_child_report(config_file, config, "failed"; validation_error=exception)
            catch report_error
                @warn "Could not write DispatchCheckup's validation failure report" exception=(report_error, catch_backtrace())
            end
            rethrow()
        end
    elseif isfile(config["report_file"]) &&
           get(TOML.parsefile(config["report_file"]), "validation_status", "") == "failed"
        # A normal finalization error may be followed by the failure exit hook.
        return nothing
    end
    return _write_child_report(config_file, config, validate ? "passed" : "not_checked")
end

function child_main(config_file::String)
    config = _validated_child_config(config_file)
    get(config, "run_kind", "checked") == "checked" || error("expected an instrumented controller")
    _CHILD_ACTIVATION[] === nothing || error("DispatchCheckup child controller cannot run the test suite twice")
    _CHILD_ACTIVATION[] = ChildActivation(abspath(config_file), config["token"], getpid())
    finished = Ref(false)
    observer = start_include_observer!(config_file)
    atexit() do code
        finished[] && return
        finished[] = true
        try
            _finish_child(config_file; validate=code == 0)
        catch exception
            showerror(stderr, exception, catch_backtrace())
            println(stderr)
            code == 0 && exit(1)
        finally
            stop_include_observer!(observer)
        end
    end
    # The bootstrap is an implementation detail. Direct scripts retain their
    # executable-file guards; Pkg.test retains its intentionally empty value.
    Core.eval(Base, :(PROGRAM_FILE = $(config["program_file"])))
    try
        Base.include(Main, config["test_entry"])
        _finish_child(config_file)
        finished[] = true
    finally
        stop_include_observer!(observer)
    end
    return nothing
end

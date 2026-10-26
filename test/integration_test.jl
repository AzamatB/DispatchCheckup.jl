# Checked runs of generated fixture packages, each in a fresh Julia process. The items share the fixture packages
# and their two environments (the setup Checkups), and each checks at its end that no run changed the packages'
# files. They come longest first: a worker that has finished its share takes the next free item from the top.
@testsetup module Checkups
using Test
include(joinpath(@__DIR__, "support.jl"))
using .Fixtures: CHECKUP, Fixtures, USES_DOCTOR, UUIDS, package_project, resolve, write_files

const WIDE = "wide(" * join(("x$i" for i in 1:36), ", ") * ") = x1 + x36"

const FIXTURE = Dict(
    "src/DCFixture.jl" => """
        module DCFixture

        export stable
        struct Wrapper end
        struct Other end

        stable(x) = x + 1
        unstable(x) = x > 0 ? x : 0.0
        twin(x) = x > 0 ? x : 0.0
        lined(x) = x > 0 ? x : 0.0
        lined(x, y) = x > 0 ? y : 0.0
        "Docs of documented."
        documented(x) = x > 0 ? x : 0.0
        @generated generated(x) = :(x)
        generated(x, y) = x > 0 ? x : 0.0
        Base.getindex(::Wrapper, i) = i > 0 ? i : 0.0
        where_dir() = @__DIR__
        $WIDE
        typed_kw(x; T = Float64) = T(x)
        const INIT_DIR = Ref("")
        __init__() = (INIT_DIR[] = something(pkgdir(@__MODULE__), ""); nothing)
        include("included.jl")
        include(identity, "mapped.jl")
        Base.include(@__MODULE__, "based.jl")
        Core.include(@__MODULE__, joinpath(@__DIR__, "cored.jl"))
        for file in ("looped.jl",)
            include(file)
        end

        module Sub
        import Base: getindex
        using ..DCFixture: Other
        unstable(x) = x > 0 ? x : 0.0
        twin(x) = x > 0 ? x : 0.0
        getindex(::Other, i) = i > 0 ? i : 0.0
        include("sub_included.jl")
        module Deeper
        deep_unstable(x) = x > 0 ? x : 0.0
        end
        end

        Sub.include("sub_more.jl")

        module NoInfer
        Base.Experimental.@compiler_options infer=false
        noinfer(x) = x > 0 ? x : 0
        end

        end
        """,
    "src/included.jl" => """
        included_unstable(x) = x > 0 ? x : 0.0
        include(joinpath("deeper", "more.jl"))
        """,
    "src/deeper/more.jl" => "more_unstable(x) = x > 0 ? x : 0.0\n",
    "src/mapped.jl" => "mapped_unstable(x) = x > 0 ? x : 0.0\n",
    "src/based.jl" => "based_unstable(x) = x > 0 ? x : 0.0\n",
    "src/cored.jl" => "cored_unstable(x) = x > 0 ? x : 0.0\n",
    "src/sub_included.jl" => "sub_included_unstable(x) = x > 0 ? x : 0.0\n",
    "src/looped.jl" => "looped_unstable(x) = x > 0 ? x : 0.0\n",
    "src/sub_more.jl" => "sub_more_unstable(x) = x > 0 ? x : 0.0\n",
    "ext/DCFixtureDatesExt.jl" => """
        module DCFixtureDatesExt
        using DCFixture, Dates
        ext_unstable(x) = x > 0 ? x : 0.0
        ext_other(x) = x > 0 ? x : 0.0
        end
        """,
    "ext/DCFixtureUnicodeExt.jl" => """
        module DCFixtureUnicodeExt
        using DCFixture, Unicode
        # DispatchDoctor applies @ccallable to its inferred copy too, which cannot work.
        Base.@ccallable ccallable(x::Int)::Int = x
        end
        """,
    "Project.toml" => package_project("DCFixture";
        weakdeps = Dict("Dates" => UUIDS["Dates"], "Unicode" => UUIDS["Unicode"]),
        extensions = Dict("DCFixtureDatesExt" => "Dates", "DCFixtureUnicodeExt" => "Unicode")),
)
line_of(code) = findfirst(==(code), split(FIXTURE["src/DCFixture.jl"], '\n'))
const LINED, DOCUMENTED = line_of("lined(x) = x > 0 ? x : 0.0"), line_of("documented(x) = x > 0 ? x : 0.0")

const BARE = Dict(
    "src/DCBare.jl" => """
        baremodule DCBare
        using Base: >, +
        bare_stable(x) = x + 1
        two_way(x) = x > 0 ? x : 0.0
        bare_unstable(x) = x > 0 ? x : x > -1 ? 0.0 : 0.0f0
        end
        """,
    "Project.toml" => package_project("DCBare"),
)

const GUARDS = Dict(
    "guard_ok.jl" => """
        using Test, DCFixture
        @test DCFixture.unstable(1) == 1
        @test !any(id -> id.name == "DispatchDoctor", keys(Base.loaded_modules))
        @test !any(startswith("DISPATCH_CHECKUP"), keys(ENV))
        @test pwd() == @__DIR__
        println("DCT_GUARD_OK ", getpid())
        """,
    "guard_fail.jl" => """
        using Test
        @test 1 == 2
        println("DCT_GUARD_FAIL_RAN")
        """,
    # Julia processes started by a checked run: plainly, and calling dispatch_doctor again.
    "child_plain.jl" => """
        using DCFixture
        checked = try DCFixture.unstable(1); false catch; true end
        println("DCT_CHILD_PLAIN ", checked, " ", pkgdir(DCFixture) == DCFixture.INIT_DIR[] == ENV["DCT_ROOT"])
        """,
    "child_own.jl" => """
        import DispatchCheckup
        DispatchCheckup.dispatch_doctor(:DCFixture; unstable = :unstable)
        using DCFixture
        println("DCT_CHILD_OWN ", DCFixture.unstable(1), " ", pkgdir(DCFixture) == ENV["DCT_ROOT"])
        """,
)

# The two lines (commented out unless `activate`), then `body`.
function script(body; pkg = :DCFixture, activate = true, options = "", prelude = "")
    lines = ["import DispatchCheckup",
             "DispatchCheckup.dispatch_doctor($(repr(pkg))$(isempty(options) ? "" : "; $options"))"]
    activate || (lines = "# " .* lines)
    return prelude * join(lines, '\n') * """

        using Test, $pkg
        detected(f, args...; kws...) = try
            f(args...; kws...)
            false
        catch e
            nameof(typeof(e)) === :TypeInstabilityError || rethrow()
            true
        end
        loaded(name) = any(id -> id.name == name, keys(Base.loaded_modules))
        """ * body
end

# Run the script `text` in `env`; with `depot`, in a depot of its own (see `depot_path`).
function run_script(env::String, name, text; depot = nothing)
    file = joinpath(env, "$name.jl")
    write(file, text)
    variables = Dict("DCT_ROOT" => root(env, "DCFixture"))
    depot === nothing || (variables["JULIA_DEPOT_PATH"] = Fixtures.depot_path(depot))
    return julia("--project=$env", file; dir = env, env = variables)
end
root(env::String, pkg) = joinpath(dirname(env), pkg)
markers(output, key) = [line for line in split(output, '\n') if startswith(line, key)]

function show_failure(result)
    result.code == 0 || println(result.output)
    return result
end

# The fixture packages and the environments that use them, `env` with DispatchCheckup and `plain` without it, in
# the main process's scratch directory. The items share them, as test sets side by side in one process did: the
# first worker to get here makes them, and the others wait for it.
const sandbox = joinpath(Main.MAIN_SCRATCH, "integration")
const env, plain = joinpath(sandbox, "env"), joinpath(sandbox, "plain")
const fixture_root = root(env, "DCFixture")
const made, failed = joinpath(Main.MAIN_SCRATCH, "integration.toml"), joinpath(Main.MAIN_SCRATCH, "integration.failed")
# The items that check DCFixture in `env` with options each use a depot of their own.
own(name) = joinpath(sandbox, "depots", name)
# The other Julia processes of these items get the sandbox's depot first (see `depot_path`): what they compile,
# and the overlays they write, go away with the sandbox.
julia(args...; env = Dict{String,String}(), kws...) = Fixtures.julia(args...;
    env = merge(Dict("JULIA_DEPOT_PATH" => Fixtures.depot_path(joinpath(sandbox, "depot"))), env), kws...)

function make_sandbox()
    write_files(joinpath(sandbox, "DCFixture"), FIXTURE)
    write_files(joinpath(sandbox, "DCBare"), BARE)
    write_files(joinpath(sandbox, "DCUsesDoctor"), USES_DOCTOR)
    before = Fixtures.snapshot(sandbox)
    deps = Dict(name => UUIDS[name] for name in ("DCFixture", "DCBare", "DCUsesDoctor", "DispatchCheckup",
                                                 "Test", "Dates", "Unicode"))
    sources = Dict(name => Dict("path" => "../$name") for name in ("DCFixture", "DCBare", "DCUsesDoctor"))
    sources["DispatchCheckup"] = Dict("path" => CHECKUP)
    # A user preference that would switch DispatchDoctor off (check 2 must override it).
    preferences = Dict(p => Dict("dispatch_doctor_mode" => "disable") for p in ("DCFixture", "DCBare"))
    write_files(env, merge(GUARDS, Dict("Project.toml" => Dict("deps" => deps, "sources" => sources),
                                        "LocalPreferences.toml" => preferences)))
    delete!(deps, "DispatchCheckup"), delete!(sources, "DispatchCheckup")
    write_files(plain, Dict("Project.toml" => Dict("deps" => deps, "sources" => sources),
                            "LocalPreferences.toml" => preferences))
    @sync (@async resolve(env); @async resolve(plain))
    # the hashes of the packages' files, written last (renamed into place): the sandbox is ready
    write(made * ".tmp", sprint(Fixtures.TOML.print, Dict(path => string(h) for (path, h) in before)))
    mv(made * ".tmp", made)
end
if (try mkdir(sandbox); true catch e; e isa Base.IOError || rethrow(); false end)
    try make_sandbox() catch; touch(failed); rethrow() end
else
    timedwait(() -> isfile(made) || isfile(failed), 600.0; pollint = 0.5) === :ok && isfile(made) ||
        error("the worker that makes the fixture packages failed (see its first item) or took longer than 10 minutes")
end
const before = Dict(path => parse(UInt64, h) for (path, h) in Fixtures.TOML.parsefile(made))

# Each item ends with this test set: no run so far changed the fixture packages' files.
files_unchanged() = @testset "the package's files are unchanged" begin
    @test all(isfile(joinpath(sandbox, path)) && hash(read(joinpath(sandbox, path))) == hash_
              for (path, hash_) in before)
end

export CHECKUP, Fixtures, UUIDS, write_files, julia, script, run_script, markers, show_failure, LINED, DOCUMENTED,
    sandbox, env, plain, fixture_root, own, files_unchanged
end

@testitem "a new configuration rebuilds the precompiled image" setup = [Checkups] begin
    for (options, body) in (("", "@test detected(DCFixture.unstable, 1)"),
                            ("unstable = :unstable", "@test DCFixture.unstable(1) == 1"),
                            ("mode = \"warn\"", "@test (@test_logs (:warn,) match_mode = :any DCFixture.unstable(1)) == 1"),
                            ("", "@test detected(DCFixture.unstable, 1)"))
        result = show_failure(run_script(env, "rebuild", depot = own("rebuild"), script(body; options)))
        @test result.code == 0
    end
    files_unchanged()
end

@testitem "checked run" setup = [Checkups] begin
    result = show_failure(run_script(env, "checked", depot = own("checked"), script("""
        using Dates, DCUsesDoctor
        @testset "checked" begin
            @test ENV["DISPATCH_CHECKUP"] == "checked"
            @test loaded("DispatchDoctor")
            # the environment's "disable" preference is overridden for this run
            @test occursin("disable", read(joinpath(dirname(Base.active_project()), "LocalPreferences.toml"), String))
            @test Base.get_preferences(Base.PkgId(DCFixture).uuid)["dispatch_doctor_mode"] == "error"
            @test DCFixture.stable(1) == 2
            for f in (DCFixture.unstable, DCFixture.twin, DCFixture.included_unstable,
                      DCFixture.more_unstable, DCFixture.mapped_unstable, DCFixture.based_unstable,
                      DCFixture.cored_unstable,
                      DCFixture.Sub.unstable, DCFixture.Sub.twin, DCFixture.Sub.sub_included_unstable,
                      DCFixture.Sub.Deeper.deep_unstable)
                @test detected(f, 1)
            end
            @test detected(getindex, DCFixture.Wrapper(), 1)
            @test detected(getindex, DCFixture.Other(), 1)
            @test detected(DCFixture.lined, 1) && detected(DCFixture.lined, 1, 2)
            @test detected(DCFixture.generated, 1, 2) && DCFixture.generated(1) == 1
            # `for f in (...) include(f) end` and `Sub.include(...)` are checked too
            @test detected(DCFixture.looped_unstable, 1) && detected(DCFixture.Sub.sub_more_unstable, 1)
            ext = Base.get_extension(DCFixture, :DCFixtureDatesExt)
            @test detected(ext.ext_unstable, 1)
            # pkgdir, pathof and @__DIR__ are those of the original checkout
            @test pkgdir(DCFixture) == ENV["DCT_ROOT"]
            @test pathof(DCFixture) == joinpath(ENV["DCT_ROOT"], "src", "DCFixture.jl")
            @test pathof(ext) == joinpath(ENV["DCT_ROOT"], "ext", "DCFixtureDatesExt.jl")
            @test DCFixture.where_dir() == joinpath(ENV["DCT_ROOT"], "src")
            @test DCFixture.INIT_DIR[] == ENV["DCT_ROOT"]  # (in __init__, from the image)
            @test isdefined(DCFixture, Symbol("#DispatchCheckup"))  # (the module doing that)
            # other packages keep the registered DispatchDoctor (and its false positive)
            @test pathof(DCUsesDoctor.DispatchDoctor) != pathof(DispatchCheckup.DispatchDoctor)
            @test detected(DCUsesDoctor.typed_kw, 1; T = Float32)
            # Julia processes started here are checked too, or with their own options
            child(file) = read(`\$(Base.julia_cmd()) --project=\$(Base.active_project()) \$file`, String)
            @test occursin("DCT_CHILD_PLAIN true true", child("child_plain.jl"))
            @test occursin("DCT_CHILD_OWN 1 true", child("child_own.jl"))
            @test detected(DCFixture.unstable, 1)
            # the fixes of the DispatchDoctor fork: wide calls, Type keywords, infer=false
            args = ntuple(Float64, Val(36))
            allocations(args) = @allocated DCFixture.wide(args...)
            @test DCFixture.wide(args...) == 37.0
            @test allocations(args) == 0
            @test DCFixture.typed_kw(1; T = Float32) === 1.0f0
            @test DCFixture.NoInfer.noinfer(1) == 1
            # the same call again does nothing; other options are an error
            @test DispatchCheckup.dispatch_doctor(:DCFixture) === nothing
            @test_throws ErrorException DispatchCheckup.dispatch_doctor(:DCFixture; mode = "warn")
        end
        """)))
    @test result.code == 0
    @test !occursin("found no compatible functions", result.output)
    files_unchanged()
end

@testitem "check (1): the package is loaded from the overlay" setup = [Checkups] begin
    early = run_script(env, "early", depot = own("overlay"), "using DCFixture\n" * script("println(\"DCT_BODY_RAN\")"))
    @test early.code != 0
    @test occursin("DCFixture is already loaded", early.output)
    @test !occursin("DCT_BODY_RAN", early.output)

    elsewhere = run_script(env, "elsewhere", depot = own("overlay"), """
        import DispatchCheckup
        DispatchCheckup.dispatch_doctor(:DCFixture)
        popfirst!(LOAD_PATH)  # loads the original package instead
        using DCFixture
        println("DCT_VALUE=", DCFixture.unstable(1))
        """)
    @test elsewhere.code != 0
    @test occursin("instead of the overlay", elsewhere.output)
    @test occursin("DCT_VALUE=1", elsewhere.output)

    # an extension that cannot be built with the checks (the trigger is loaded)
    broken = run_script(env, "broken_ext", depot = own("overlay"), script("using Unicode\nprintln(\"DCT_BODY_RAN\")"))
    @test broken.code != 0
    @test occursin("the extension DCFixtureUnicodeExt did not load", broken.output)
    @test occursin("DCT_BODY_RAN", broken.output)

    never = run_script(env, "never", depot = own("overlay"), "import DispatchCheckup\n" *
                       "DispatchCheckup.dispatch_doctor(:DCFixture)\nprintln(\"DCT_BODY_RAN\")\n")
    @test never.code != 0
    @test occursin("never loaded, so nothing was checked", never.output)
    @test occursin("DCT_BODY_RAN", never.output)
    files_unchanged()
end

@testitem "original= guards" setup = [Checkups] begin
    body = """
        @test detected(DCFixture.unstable, 1)
        get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("guard_ok.jl")
        println("DCT_SUITE_DONE ", getpid())
        """
    ok = show_failure(run_script(env, "guarded", depot = own("guards"), script(body; options = "original = \"guard_ok.jl\"")))
    @test ok.code == 0
    @test length(markers(ok.output, "DCT_GUARD_OK")) == 1
    @test only(markers(ok.output, "DCT_GUARD_OK"))[14:end] != only(markers(ok.output, "DCT_SUITE_DONE"))[16:end]
    @test something(findfirst("DCT_SUITE_DONE", ok.output))[1] < something(findfirst("DCT_GUARD_OK", ok.output))[1]

    failing = run_script(env, "failing", depot = own("guards"), script(body; options = "original = (\"guard_fail.jl\", \"guard_ok.jl\")"))
    @test failing.code != 0
    @test occursin("DCT_GUARD_FAIL_RAN", failing.output)
    @test length(markers(failing.output, "DCT_GUARD_OK")) == 1

    off = show_failure(run_script(env, "guard_off", depot = own("guards"), script("""
        get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("guard_ok.jl")
        """; activate = false, options = "original = \"guard_ok.jl\"")))
    @test off.code == 0
    @test length(markers(off.output, "DCT_GUARD_OK")) == 1
    files_unchanged()
end

@testitem "runs with other options do not share an overlay" setup = [Checkups] begin
    # An independent run of the same checkout, excluding `unstable`, activates and loads
    # the package between this run's activation and its `using`.
    result = show_failure(run_script(env, "race", depot = own("race"), """
        import DispatchCheckup
        DispatchCheckup.dispatch_doctor(:DCFixture)
        other = filter(p -> !startswith(first(p), "DISPATCH_CHECKUP"), copy(ENV))
        other["JULIA_LOAD_PATH"] = "@:@stdlib"
        run(setenv(`\$(Base.julia_cmd()) --project=\$(Base.active_project()) child_own.jl`, other))
        using Test, DCFixture
        @test_throws DispatchCheckup.DispatchDoctor.TypeInstabilityError DCFixture.unstable(1)
        """))
    @test result.code == 0
    @test occursin("DCT_CHILD_OWN 1 true", result.output)
    files_unchanged()
end

# The Godela suites run their test items on ReTestItems' workers: Julia processes that a checked run starts, which
# load the checked package too. DCFixture's test/runtests.jl here makes a checked run that hands one item to one
# worker, in an environment of the test environment's manifest (which has ReTestItems), plus DCFixture.
@testitem "a checked run's ReTestItems workers run the checked package" setup = [Checkups] begin
    rti = joinpath(sandbox, "rti")
    project = something(Base.active_project())
    manifest = Fixtures.TOML.parsefile(something(Base.project_file_manifest_path(project)))
    for records in values(manifest["deps"]), record in records
        haskey(record, "path") && (record["path"] = normpath(dirname(project), record["path"]))
    end
    write_files(rti, Dict(
        "Manifest.toml" => manifest,
        "Project.toml" => Dict(
            "deps" => Dict(n => UUIDS[n] for n in ("DCFixture", "DispatchCheckup", "ReTestItems", "Test")),
            "sources" => Dict("DCFixture" => Dict("path" => fixture_root), "DispatchCheckup" => Dict("path" => CHECKUP))),
        "test/runtests.jl" => """
            import DispatchCheckup
            DispatchCheckup.dispatch_doctor(:DCFixture)
            using DCFixture, ReTestItems
            println("DCT_MAIN ", getpid())
            ReTestItems.runtests(@__DIR__; nworkers = 1, nworker_threads = 1)
            """,
        "test/worker_test.jl" => """
            @testitem "the worker" begin
                import DispatchCheckup
                using DCFixture
                @test ENV["DISPATCH_CHECKUP"] == "checked"
                @test isdefined(DCFixture, Symbol("#DispatchCheckup"))
                @test_throws DispatchCheckup.DispatchDoctor.TypeInstabilityError DCFixture.unstable(1)
                @test pkgdir(DCFixture) == ENV["DCT_ROOT"]
                write(ENV["DCT_PID"], string(getpid()))
            end
            """))
    Fixtures.resolve(rti)
    result = show_failure(julia("--project=$rti", joinpath(rti, "test", "runtests.jl"); dir = rti,
                                env = Dict("DCT_ROOT" => fixture_root, "DCT_PID" => joinpath(rti, "worker.pid"))))
    @test result.code == 0
    # (the item ran, on a worker: another process than the checked run's)
    pidfile, main = joinpath(rti, "worker.pid"), markers(result.output, "DCT_MAIN ")
    @test length(main) == 1 && isfile(pidfile) && only(main) != "DCT_MAIN " * read(pidfile, String)
    files_unchanged()
end

@testitem "commented out: as if DispatchCheckup did not exist" setup = [Checkups] begin
    body = """
        using DCUsesDoctor
        println("DCT_PATHOF=", pathof(DCFixture))
        println("DCT_USES_DOCTOR=", pathof(DCUsesDoctor.DispatchDoctor), " ",
                detected(DCUsesDoctor.typed_kw, 1; T = Float32))
        println("DCT_VALUES=", DCFixture.unstable(1), " ", DCFixture.Sub.twin(-1))
        println("DCT_FORK=", any(id -> string(id.uuid) == "$(UUIDS["DispatchDoctor"])",
                                 keys(Base.loaded_modules)))
        println("DCT_ENV=", sort!(filter(startswith("DISPATCH_CHECKUP"), collect(keys(ENV)))))
        println("DCT_LOAD_PATH=", LOAD_PATH)
        println("DCT_MODULES=", sort!([id.name for id in keys(Base.loaded_modules)]))
        """
    off = show_failure(run_script(env, "off", script(body; activate = false)))
    absent = show_failure(run_script(plain, "absent", script(body; activate = false)))
    @test off.code == absent.code == 0
    @test markers(off.output, "DCT_") == markers(absent.output, "DCT_")
    @test "DCT_VALUES=1 0.0" in markers(off.output, "DCT_VALUES")
    @test "DCT_FORK=false" in markers(off.output, "DCT_FORK")
    @test endswith(only(markers(off.output, "DCT_USES_DOCTOR")), " true")  # (registered)
    @test "DCT_PATHOF=$(joinpath(fixture_root, "src", "DCFixture.jl"))" in markers(off.output, "DCT_PATHOF")
    files_unchanged()
end

@testitem "unstable= forms" setup = [Checkups] begin
    options = "unstable = (:unstable, Symbol(\"DCFixture.Sub.twin\"), " *
              "Symbol(\"DCFixtureDatesExt.ext_unstable\"), Symbol(\"Base.getindex\"), " *
              ":lined => \"src/DCFixture.jl:$LINED\", :documented => \"src/DCFixture.jl:$DOCUMENTED\", " *
              ":generated, :ccallable, :looped_unstable, Symbol(\"DCFixture.Sub.sub_more_unstable\"))"
    result = show_failure(run_script(env, "forms", depot = own("forms"), script("""
        using Dates, Unicode
        ext = Base.get_extension(DCFixture, :DCFixtureDatesExt)
        @testset "forms" begin
            # :foo excludes every definition named foo, in any module
            @test DCFixture.unstable(1) == 1 && DCFixture.Sub.unstable(1) == 1
            # Symbol("Mod.foo") excludes only those in that module (or an extension)
            @test DCFixture.Sub.twin(1) == 1 && detected(DCFixture.twin, 1)
            @test ext.ext_unstable(1) == 1 && detected(ext.ext_other, 1)
            # Symbol("Base.getindex") excludes only definitions written that way
            @test DCFixture.Wrapper()[1] == 1 && detected(getindex, DCFixture.Other(), 1)
            # :foo => "file:line" excludes only the definition at that line
            @test DCFixture.lined(1) == 1 && detected(DCFixture.lined, 1, 2)
            # definitions behind macros (@unstable goes around the macros)
            @test DCFixture.documented(1) == 1 && occursin("Docs of documented", string(@doc DCFixture.documented))
            @test DCFixture.generated(1, 2) == 1 && DCFixture.generated(1) == 1
            @test Base.get_extension(DCFixture, :DCFixtureUnicodeExt).ccallable(1) == 1
            # files from include calls in loops and with a module argument
            @test DCFixture.looped_unstable(1) == 1 && DCFixture.Sub.sub_more_unstable(1) == 1
            # and nothing else
            for f in (DCFixture.included_unstable, DCFixture.more_unstable,
                      DCFixture.Sub.sub_included_unstable, DCFixture.Sub.Deeper.deep_unstable)
                @test detected(f, 1)
            end
        end
        """; options)))
    @test result.code == 0
    files_unchanged()
end

@testitem "the package is the active project" setup = [Checkups] begin
    file = joinpath(env, "active.jl")
    write(file, script("""
        @test detected(DCFixture.unstable, 1) && stable(1) == 2
        @test pkgdir(DCFixture) == ENV["DCT_ROOT"]
        """))
    separator = Sys.iswindows() ? ";" : ":"
    result = show_failure(julia("--project=$fixture_root", file; dir = env, env = Dict(
        "DCT_ROOT" => fixture_root, "JULIA_LOAD_PATH" => join(["@", env, "@stdlib"], separator))))
    @test result.code == 0
    files_unchanged()
end

@testitem "check (2): the DispatchDoctor fork must be loaded" setup = [Checkups] begin
    fake = joinpath(sandbox, "FakeDoctor")
    write_files(fake, Dict("src/DispatchDoctor.jl" => "module DispatchDoctor\nconst JULIA_OK = true\nend\n",
                           "Project.toml" => Dict("name" => "DispatchDoctor", "uuid" => UUIDS["DispatchDoctor"],
                                                  "version" => "0.4.29")))
    unforked = joinpath(sandbox, "unforked")
    manifest = Fixtures.TOML.parsefile(joinpath(env, "Manifest.toml"))
    for records in values(manifest["deps"]), record in records
        haskey(record, "path") && (record["path"] = normpath(env, record["path"]))
    end
    records = manifest["deps"]["DispatchDoctor"]::Vector{Any}  # (the fork and the registered one)
    records[findfirst(r -> r["uuid"] == UUIDS["DispatchDoctor"], records)] =
        Dict("uuid" => UUIDS["DispatchDoctor"], "version" => "0.4.29", "path" => fake)
    write_files(unforked, Dict("Project.toml" => Fixtures.TOML.parsefile(joinpath(env, "Project.toml")),
                               "Manifest.toml" => manifest))
    result = run_script(unforked, "unforked", script("println(\"DCT_BODY_RAN\")"))
    @test result.code != 0
    @test occursin("needs the DispatchDoctor fork", result.output)
    @test occursin(joinpath(fake, "src", "DispatchDoctor.jl"), result.output)
    @test !occursin("DCT_BODY_RAN", result.output)
    files_unchanged()
end

@testitem "a package that uses the registered DispatchDoctor itself" setup = [Checkups] begin
    result = show_failure(run_script(env, "uses_doctor", script("""
        @testset "uses doctor" begin
            # its own @stable blocks are left to the registered DispatchDoctor
            registered, fork = DCUsesDoctor.DispatchDoctor, DispatchCheckup.DispatchDoctor
            @test_throws registered.TypeInstabilityError DCUsesDoctor.typed_kw(1; T = Float32)
            @test_throws fork.TypeInstabilityError DCUsesDoctor.plain_unstable(1)
        end
        """; pkg = :DCUsesDoctor)))
    @test result.code == 0
    files_unchanged()
end

@testitem "baremodule target with union_limit" setup = [Checkups] begin
    result = show_failure(run_script(env, "bare", script("""
        @testset "bare" begin
            @test DCBare.bare_stable(1) == 2
            @test !detected(DCBare.two_way, 1)
            @test detected(DCBare.bare_unstable, 1)
        end
        """; pkg = :DCBare, options = "union_limit = 2")))
    @test result.code == 0
    files_unchanged()
end

@testitem "check (3): unmatched unstable= entries fail before the tests" setup = [Checkups] begin
    result = run_script(env, "unmatched", script("println(\"DCT_BODY_RAN\")";
        options = "unstable = (:unstabel, :lined => \"src/DCFixture.jl:999\", :twin)"))
    @test result.code != 0
    @test occursin("match no definition", result.output)
    @test occursin(r"unstabel .*nearest: unstable", result.output)
    @test occursin("lined => src/DCFixture.jl:999", result.output)
    @test !occursin("  twin", result.output)
    @test !occursin("DCT_BODY_RAN", result.output)
    files_unchanged()
end

# Pkg.test with both test layouts and with the registered DispatchDoctor as a test
# dependency, a consumer environment that gets the DispatchDoctor fork through
# DispatchCheckup's [sources], and a workspace whose root's preferences must reach a checked
# run. Each item uses packages of its own, in a directory of its own.
@testsetup module Layouts
using Test
include(joinpath(@__DIR__, "support.jl"))
using .Fixtures: CHECKUP, Fixtures, USES_DOCTOR, UUIDS, julia, package_project, write_files

const LAYOUT_TESTS = """
    import DispatchCheckup
    DispatchCheckup.dispatch_doctor(:PKG; original = "guards.jl")
    using Test, PKG
    @testset "PKG" begin
        @test PKG.stable(1) == 2
        @test_throws DispatchCheckup.DispatchDoctor.TypeInstabilityError PKG.unstable(1)
        # the active project is still Pkg's test environment, also in the processes started here
        @test !occursin("dispatchcheckup-", Base.active_project())
        @test haskey(Base.parsed_toml(Base.active_project())["deps"], "DispatchCheckup")
        @test readchomp(`\$(Base.julia_cmd()) -e 'print(Base.active_project())'`) == Base.active_project()
        println("DCT_CHECKED")
    end
    get(ENV, "DISPATCH_CHECKUP", "") == "checked" || include("guards.jl")
    """
const LAYOUT_GUARDS = """
    using Test, PKG
    @test PKG.unstable(1) == 1
    println("DCT_GUARDED")
    """
layout_files(pkg; header = "") = Dict(
    "src/$pkg.jl" => "module $pkg\n$(header)stable(x) = x + 1\nunstable(x) = x > 0 ? x : 0.0\nend\n",
    "test/runtests.jl" => replace(LAYOUT_TESTS, "PKG" => pkg),
    "test/guards.jl" => replace(LAYOUT_GUARDS, "PKG" => pkg))

# A package whose tests also use the registered DispatchDoctor (a test dependency): its
# `allow_unstable` pauses the checks (on every thread; the checked run has four), and with
# the two lines commented out the fork is not loaded at all.
const ALLOW_UNSTABLE_TESTS = """
    LINES
    using Test, DCAllowUnstable
    import DispatchDoctor  # the registered package
    @testset "DCAllowUnstable" begin
        @test string(Base.PkgId(DispatchDoctor).uuid) == "$(Fixtures.REGISTERED_DOCTOR)"
        @test DCAllowUnstable.stable(1) == 2
        @test DispatchDoctor.allow_unstable(() -> DCAllowUnstable.unstable(1)) == 1
        if get(ENV, "DISPATCH_CHECKUP", "") == "checked"
            fork = DispatchCheckup.DispatchDoctor
            @test string(Base.PkgId(fork).uuid) == "$(UUIDS["DispatchDoctor"])"
            # outside allow_unstable (also after it), the fork's TypeInstabilityError
            thrown = try DCAllowUnstable.unstable(1); nothing catch e; e end
            @test thrown isa fork.TypeInstabilityError
            @test !(thrown isa DispatchDoctor.TypeInstabilityError)
            @test DispatchDoctor.allow_unstable() do
                DispatchDoctor.allow_unstable(() -> DCAllowUnstable.unstable(1)) +
                DCAllowUnstable.unstable(-1)
            end == 1
            @test_throws fork.TypeInstabilityError DCAllowUnstable.unstable(1)
            # threads that run checked code inside one allow_unstable are all paused
            @test Threads.nthreads() == 4
            function threaded(n)
                Threads.@threads for i in 1:n
                    DCAllowUnstable.unstable(i)
                end
                return n
            end
            @test DispatchDoctor.allow_unstable(() -> threaded(4000)) == 4000
            thrown = try threaded(4000); nothing catch e; e end
            while thrown isa CompositeException || thrown isa TaskFailedException
                thrown = thrown isa CompositeException ? first(thrown.exceptions) : thrown.task.exception
            end
            @test thrown isa fork.TypeInstabilityError
            println("DCT_CHECKED")
        else
            @test DCAllowUnstable.unstable(1) == 1
            doctors = [id for id in keys(Base.loaded_modules) if id.name == "DispatchDoctor"]
            @test doctors == [Base.PkgId(DispatchDoctor)]
            @test !haskey(Base.loaded_modules, Base.PkgId(Base.UUID("$(UUIDS["DispatchDoctor"])"), "DispatchDoctor"))
            println("DCT_ORDINARY")
        end
    end
    """
const ALLOW_UNSTABLE_LINES = "import DispatchCheckup\nDispatchCheckup.dispatch_doctor(:DCAllowUnstable)"

export ALLOW_UNSTABLE_LINES, ALLOW_UNSTABLE_TESTS, CHECKUP, Fixtures, USES_DOCTOR, UUIDS, julia, layout_files,
    package_project, write_files
end

@testitem "the registered DispatchDoctor's allow_unstable" setup = [Layouts] begin
    mktempdir() do sandbox
        dir = joinpath(sandbox, "DCAllowUnstable")
        write_files(dir, Dict(
            "Project.toml" => package_project("DCAllowUnstable"),
            "src/DCAllowUnstable.jl" => """
                module DCAllowUnstable
                stable(x) = x + 1
                unstable(x) = x > 0 ? x : 0.0
                end
                """,
            "test/Project.toml" => Dict(
                "deps" => merge(Dict(n => UUIDS[n] for n in ("DCAllowUnstable", "DispatchCheckup", "Test")),
                                Dict("DispatchDoctor" => Fixtures.REGISTERED_DOCTOR)),
                "compat" => Dict("DispatchCheckup" => "0.2", "DispatchDoctor" => "0.4.29"),
                "sources" => Dict("DCAllowUnstable" => Dict("path" => ".."),
                                  "DispatchCheckup" => Dict("path" => CHECKUP)))))
        for (lines, marker, args) in ((ALLOW_UNSTABLE_LINES, "DCT_CHECKED", "julia_args = [\"--threads=4\"]"),
                                      (replace(ALLOW_UNSTABLE_LINES, r"^"m => "# "), "DCT_ORDINARY", ""))
            write_files(dir, Dict("test/runtests.jl" => replace(ALLOW_UNSTABLE_TESTS, "LINES" => lines)))
            result = julia("--project=$dir", "-e", "using Pkg; Pkg.test($args)"; dir)
            result.code == 0 || println(result.output)
            @test result.code == 0
            @test occursin(marker, result.output)
        end
    end
    Fixtures.remove_overlays("DCAllowUnstable")
end

@testitem "Pkg.test with [extras] and [targets]" setup = [Layouts] begin
    mktempdir() do sandbox
        # (with a dependency that uses the registered DispatchDoctor, which the fork leaves alone)
        write_files(joinpath(sandbox, "DCUsesDoctor"), USES_DOCTOR)
        dir = joinpath(sandbox, "DCLayoutA")
        files = layout_files("DCLayoutA"; header = "import DCUsesDoctor\n")
        write_files(dir, merge(files, Dict("Project.toml" => package_project("DCLayoutA";
            deps = Dict("DCUsesDoctor" => UUIDS["DCUsesDoctor"]),
            extras = Dict("DispatchCheckup" => UUIDS["DispatchCheckup"], "Test" => UUIDS["Test"]),
            targets = Dict("test" => ["DispatchCheckup", "Test"]),
            compat = Dict("DispatchCheckup" => "0.2"),
            sources = Dict("DispatchCheckup" => Dict("path" => CHECKUP),
                           "DCUsesDoctor" => Dict("path" => "../DCUsesDoctor"))))))
        result = julia("--project=$dir", "-e", "using Pkg; Pkg.test()"; dir)
        result.code == 0 || println(result.output)
        @test result.code == 0
        @test occursin("DCT_CHECKED", result.output) && occursin("DCT_GUARDED", result.output)
    end
    Fixtures.remove_overlays("DCLayoutA")
end

@testitem "Pkg.test with test/Project.toml" setup = [Layouts] begin
    mktempdir() do sandbox
        dir = joinpath(sandbox, "DCLayoutB")
        write_files(dir, merge(layout_files("DCLayoutB"), Dict(
            "Project.toml" => package_project("DCLayoutB"),
            "test/Project.toml" => Dict(
                "deps" => Dict(n => UUIDS[n] for n in ("DCLayoutB", "DispatchCheckup", "Test")),
                "compat" => Dict("DispatchCheckup" => "0.2"),
                "sources" => Dict("DCLayoutB" => Dict("path" => ".."),
                                  "DispatchCheckup" => Dict("path" => CHECKUP))))))
        result = julia("--project=$dir", "-e", "using Pkg; Pkg.test()"; dir)
        result.code == 0 || println(result.output)
        @test result.code == 0
        @test occursin("DCT_CHECKED", result.output) && occursin("DCT_GUARDED", result.output)
    end
    Fixtures.remove_overlays("DCLayoutB")
end

@testitem "a consumer gets the DispatchDoctor fork through recursive [sources]" setup = [Layouts] begin
    mktempdir() do sandbox
        # Adding a git repository by path is what adding DispatchCheckup by URL does.
        repo = joinpath(sandbox, "DispatchCheckup.jl")
        mkpath(repo)
        for name in ("Project.toml", "LICENSE", "src")
            cp(joinpath(CHECKUP, name), joinpath(repo, name))
        end
        git = ["git", "-C", repo, "-c", "user.name=test", "-c", "user.email=test@example.com"]
        run(`$git init -q`), run(`$git add -A`), run(`$git commit -qm DispatchCheckup`)
        consumer, depot = joinpath(sandbox, "consumer"), joinpath(sandbox, "depot")
        mkpath(consumer)
        separator = Sys.iswindows() ? ";" : ":"
        result = julia("--project=$consumer", "-e", """
            using Pkg
            Pkg.add(path = $(repr(repo)))
            using DispatchCheckup
            doctor = DispatchCheckup.DispatchDoctor
            println("DCT_MARKER=", isdefined(doctor, :DISPATCHCHECKUP_PATCHLEVEL))
            println("DCT_SOURCE=", Pkg.dependencies()[Base.PkgId(doctor).uuid].git_source)
            """; dir = consumer, env = Dict("JULIA_DEPOT_PATH" => depot * separator))
        result.code == 0 || println(result.output)
        @test result.code == 0
        @test occursin("DCT_MARKER=true", result.output)
        @test occursin("DCT_SOURCE=https://github.com/AzamatB/DispatchDoctor.jl", result.output)
    end
end

# A workspace whose root pins a preference of a package that reads it at precompile time, as a JLL reads its toolkit
# preference: the checked run puts its environment first on the load path, and Base walks a workspace up to its root's
# preferences only from that first entry, so the run carries the preferences over. The run, a process it starts in
# its project with the inherited JULIA_LOAD_PATH (as a ReTestItems worker or an item's child is), and the package's
# precompiled image all see the pin; DispatchDoctor's mode stays the run's over the root's "disable".
@testitem "a workspace root's preferences reach the checked run and its processes" setup = [Layouts] begin
    mktempdir() do sandbox
        pinned, user = UUIDS["DCPinned"], UUIDS["DCPinUser"]
        pin = "get(Base.get_preferences(Base.UUID(\"$pinned\")), \"version\", \"none\")"
        expected = Dict("DCPinned" => Dict("version" => "13.4"),
                        "DCPinUser" => Dict("dispatch_doctor_mode" => "error", "dispatch_doctor_union_limit" => 1,
                                            "dispatch_doctor_codegen_level" => "debug", "kept" => "yes"))
        write_files(sandbox, Dict(
            "Project.toml" => Dict("workspace" => Dict("projects" => ["app", "DCPinUser", "DCPinned"]),
                                   "extras" => Dict("DCPinned" => pinned, "DCPinUser" => user)),
            "LocalPreferences.toml" => Dict("DCPinned" => Dict("version" => "13.4"),
                                            "DCPinUser" => Dict("dispatch_doctor_mode" => "disable", "kept" => "yes")),
            "DCPinned/Project.toml" => package_project("DCPinned"),
            "DCPinned/src/DCPinned.jl" => """
                module DCPinned
                # read at precompile time and recorded, so an image built under another value does not load
                Base.record_compiletime_preference(Base.UUID("$pinned"), "version")
                const PIN = $pin
                end
                """,
            "DCPinUser/Project.toml" => package_project("DCPinUser"; deps = Dict("DCPinned" => pinned)),
            "DCPinUser/src/DCPinUser.jl" => "module DCPinUser\nimport DCPinned\npinned() = DCPinned.PIN\nend\n",
            "app/Project.toml" => Dict(
                "deps" => Dict("DCPinUser" => user, "DCPinned" => pinned, "DispatchCheckup" => UUIDS["DispatchCheckup"]),
                "sources" => Dict("DispatchCheckup" => Dict("path" => CHECKUP))),
            "app/run.jl" => """
                println("DCT_BEFORE ", $pin)
                import DispatchCheckup
                DispatchCheckup.dispatch_doctor(:DCPinUser)
                println("DCT_AFTER ", $pin)
                using DCPinUser
                println("DCT_IMAGE ", DCPinUser.pinned())
                environment = ENV["DISPATCH_CHECKUP_ENVIRONMENT"]
                println("DCT_PREFERENCES ", Base.parsed_toml(joinpath(environment, "LocalPreferences.toml")) == $(repr(expected)))
                child = "import DCPinUser; println(\\"DCT_CHILD \\", $(escape_string(pin)), \\" \\", DCPinUser.pinned())"
                run(`\$(Base.julia_cmd()) --startup-file=no --project=\$(Base.active_project()) -e \$child`)
                """))
        app = joinpath(sandbox, "app")
        Fixtures.resolve(app)
        result = julia("--project=$app", joinpath(app, "run.jl"); dir = app)
        result.code == 0 || println(result.output)
        @test result.code == 0
        marker(key) = something(findfirst(l -> startswith(l, key * " "), split(result.output, '\n')), 0)
        line(key) = (i = marker(key); i == 0 ? "" : split(result.output, '\n')[i][length(key)+2:end])
        @test line("DCT_BEFORE") == "13.4"   # the fixture pins it (the control)
        @test line("DCT_AFTER") == "13.4"
        @test line("DCT_IMAGE") == "13.4"
        @test line("DCT_PREFERENCES") == "true"
        @test line("DCT_CHILD") == "13.4 13.4"
    end
    Fixtures.remove_overlays("DCPinUser")
end

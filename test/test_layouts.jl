# Pkg.test with both test layouts, and a consumer environment that gets the
# DispatchDoctor fork through DispatchCheckup's [sources].
using Test
isdefined(@__MODULE__, :Fixtures) || include("support.jl")
using .Fixtures: Fixtures, UUIDS, CHECKUP, USES_DOCTOR, write_files, package_project, julia

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

mktempdir() do sandbox
    @testset "Pkg.test with [extras] and [targets]" begin
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
        Fixtures.remove_overlays("DCLayoutA")
    end

    @testset "Pkg.test with test/Project.toml" begin
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
        Fixtures.remove_overlays("DCLayoutB")
    end

    @testset "a consumer gets the DispatchDoctor fork through recursive [sources]" begin
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

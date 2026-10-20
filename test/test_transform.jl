# The unstable= matcher, the include rewriting and argument checks, in this process
# (nothing here activates DispatchCheckup).
using Test
import DispatchCheckup
const DC = DispatchCheckup

definition(code; modpath = "M", root = "/pkg") =
    DC._definition(Meta.parse(code; filename = "/pkg/src/M.jl"), modpath, root)

excluded(entry, code; kws...) = DC._excludes(only(DC._exclusions(entry)), definition(code; kws...))

@testset "unstable= entries" begin
    @test length(DC._exclusions(:foo)) == 1
    @test length(DC._exclusions(:foo => "src/M.jl:3")) == 1
    @test length(DC._exclusions([:foo, :bar])) == 2
    @test length(DC._exclusions(Set([:foo, :bar, :baz]))) == 3
    e = only(DC._exclusions(Symbol("M.Sub.foo") => "src/a.jl:12"))
    @test (e.qualifier, e.final, e.file, e.line) == ("M.Sub", "foo", normpath("src/a.jl"), 12)
    @test only(DC._exclusions(Symbol("Base.:+"))).final == "+"
    @test only(DC._exclusions(Symbol("Base.:(==)"))).final == "=="
    @test only(DC._exclusions(:..)).qualifier == ""
    @test_throws ArgumentError DC._exclusions(("foo",))
    @test_throws ArgumentError DC._exclusions(:foo => "src/M.jl")
end

@testset "definitions" begin
    d = definition("Base.getindex(x::T, i) where {T} = 1")
    @test (d.written, d.final, d.file, d.line) == ("Base.getindex", "getindex", normpath("src/M.jl"), 1)
    @test definition("function Base.:+(a, b)\n a\nend").written == "Base.+"
    @test definition("(f::Foo)(x) = 1").final == ""
    @test definition("x -> x").final == ""
    @test definition("function f end") === nothing
    @test definition("a[i] = 1") === nothing
    @test definition("x = f(y)") === nothing
    # a line without a file (from a user's include mapper, say)
    nofile = DC._definition(Expr(:(=), :(f(x)), Expr(:block, LineNumberNode(3), :x)), "M", "/pkg")
    @test (nofile.final, nofile.file, nofile.line) == ("f", "", 3)
    # a definition behind macros (`@generated`, docstrings, ...)
    @test DC._definition(DC._unwrap(Meta.parse("@generated f(x) = :(x)")), "M", "/pkg").final == "f"
    @test DC._definition(DC._unwrap(Meta.parse("\"doc\"\nBase.@ccallable f(x::Int)::Int = x")), "M", "/pkg").final == "f"
end

@testset "matching" begin
    @test excluded(:foo, "foo(x) = 1")
    @test excluded(:foo, "M.foo(x) = 1")
    @test !excluded(:foo, "foobar(x) = 1")
    @test excluded(Symbol("M.Sub.foo"), "foo(x) = 1"; modpath = "M.Sub")
    @test !excluded(Symbol("M.Sub.foo"), "foo(x) = 1"; modpath = "M")
    @test excluded(Symbol("M.foo"), "M.foo(x::Date) = 1"; modpath = "MDatesExt")
    @test excluded(Symbol("Base.getindex"), "Base.getindex(x, i) = 1")
    @test !excluded(Symbol("Base.getindex"), "getindex(x, i) = 1")
    @test excluded(:foo => "src/M.jl:1", "foo(x) = 1")
    @test !excluded(:foo => "src/M.jl:2", "foo(x) = 1")
    @test !excluded(:foo => "src/N.jl:1", "foo(x) = 1")
    # operators as DispatchDoctor prints them
    @test excluded(Symbol("Base.:+"), "Base.:+(a, b) = 1")
    @test excluded(Symbol("Base.+"), "Base.:+(a, b) = 1")
    @test excluded(Symbol("Base.:(==)"), "Base.:(==)(a, b) = 1")
    @test !excluded(Symbol("Base.:+"), "Base.:-(a, b) = 1")
end

@testset "include calls" begin
    call(code) = DC._include_call(Meta.parse(code))
    @test call("include(\"a.jl\")")[[1, 3]] == (identity, "a.jl")
    @test call("include(f, \"a.jl\")")[[1, 3]] == (:f, "a.jl")
    @test call("Base.include(M, \"a.jl\")") == (identity, :M, "a.jl")
    @test call("Base.include(f, M, \"a.jl\")") == (:f, :M, "a.jl")
    @test call("Core.include(M, \"a.jl\")") == (identity, :M, "a.jl")
    @test call("Sub.include(\"a.jl\")") == (identity, :Sub, "a.jl")
    @test call("Sub.include(f, \"a.jl\")") == (:f, :Sub, "a.jl")
    @test call("include(files...)") === nothing
    @test call("include()") === nothing
    @test call("include_string(M, code)") === nothing
    @test call("foreach(include, files)") === nothing
    # `x.include(...)` where `x` is not a module is called as written
    @test DC._include(identity, (include = p -> "included $p",), "a.jl") == "included a.jl"
    @test DC._include(:f, (include = (f, p) -> "$f $p",), "a.jl") == "f a.jl"
    path(code) = DC._path(Meta.parse(code), "/src/M.jl")
    @test path("\"a.jl\"") == "a.jl"
    @test path("joinpath(@__DIR__, \"a\", \"b.jl\")") == "/src/a/b.jl"
    @test path("joinpath(dirname(@__FILE__), \"b.jl\")") == "/src/b.jl"
    @test path("\"\$(@__DIR__)/b.jl\"") == "/src/b.jl"
    @test path("file") === nothing
    @test path("joinpath(@__DIR__, file)") === nothing
    @test DC._modpath(Meta.parse("@__MODULE__"), "M.Sub") == "M.Sub"
    @test DC._modpath(:Deeper, "M.Sub") == "M.Sub.Deeper"
    @test DC._modpath(:M, "M.Sub") == "M"
    @test DC._modpath(Meta.parse("parentmodule(@__MODULE__)"), "M.Sub") === nothing
end

@testset "the static scan" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "src", "M.jl"), """
            module M
            module Sub end
            Base.include(Sub, "into_sub.jl")
            for file in ("looped.jl",)
                include(file)
            end
            include(joinpath(dirname(@__FILE__), "joined.jl"))
            include(some_file)
            Base.include(parentmodule(@__MODULE__), "elsewhere.jl")
            \"docs\"
            Base.:+(a::Int, b::String) = a
            end
            """)
        for name in ("into_sub", "looped", "joined", "elsewhere")
            write(joinpath(root, "src", "$name.jl"), "$name(x) = x\n")
        end
        found, skipped = DC._scan(root, [joinpath(root, "src", "M.jl")])
        @test Set((d.modpath, d.final) for d in found) ==
              Set([("M.Sub", "into_sub"), ("M", "looped"), ("M", "joined"), ("M", "+")])
        @test length(skipped) == 2 && all(startswith(joinpath("src", "M.jl")), skipped)
        e = try
            DC._check_matches(root, [joinpath(root, "src", "M.jl")], DC._exclusions(
                (Symbol("M.Sub.into_sub"), :looped, Symbol("Base.:+"), Symbol("M.into_sub"), :elsewhere)))
            nothing
        catch e
            e
        end
        message = sprint(showerror, e)
        @test occursin(r"  M.into_sub   \(nearest: .*M.Sub.into_sub", message)
        @test occursin("  elsewhere", message) && !occursin("  looped", message)
        @test occursin("could not be followed", message) && occursin("include(some_file)", message)
        @test occursin("Base.include(parentmodule(@__MODULE__()), \"elsewhere.jl\")", message)
        @test occursin("Base.+", sprint(showerror, try
            DC._check_matches(root, [joinpath(root, "src", "M.jl")], DC._exclusions(Symbol("Base.+-")))
        catch e
            e
        end))
    end
end

@testset "check (2) sees the package's preferences" begin
    mktempdir() do dir
        uuid = Base.UUID("6f1d3c34-6b1a-4c39-9a38-2c0d2ad0e0a1")
        write(joinpath(dir, "Project.toml"), "[deps]\nDCPrefs = \"$uuid\"\n")
        write(joinpath(dir, "LocalPreferences.toml"), "[DCPrefs]\ndispatch_doctor_mode = \"warn\"\n")
        config(mode) = DC.Config((Base.PkgId(uuid, "DCPrefs"), dir, DC.Exclusion[], mode, 1))
        pushfirst!(LOAD_PATH, dir)
        try
            @test DC._check_options(uuid, config("warn")) === nothing
            e = try DC._check_options(uuid, config("error")); nothing catch e; e end
            @test occursin("would use (mode = \"warn\"", sprint(showerror, e))
            @test occursin("in DCPrefs, not the requested (mode = \"error\"", sprint(showerror, e))
        finally
            popfirst!(LOAD_PATH)
        end
    end
end

@testset "arguments are checked before anything changes" begin
    load_path = copy(LOAD_PATH)
    @test_throws ArgumentError DC.dispatch_doctor(:Test; mode = "disable")
    @test_throws ArgumentError DC.dispatch_doctor(:Test; union_limit = 0)
    @test_throws ArgumentError DC.dispatch_doctor(:Test; unstable = ("foo",))
    @test_throws ArgumentError DC.dispatch_doctor(:Test; original = "no_such_file.jl")
    @test_throws ErrorException DC.dispatch_doctor(:NoSuchPackage)
    @test_throws ErrorException DC.dispatch_doctor(:Test)  # already loaded
    @test LOAD_PATH == load_path
    @test !haskey(ENV, "DISPATCH_CHECKUP")
    @test DC.ACTIVE[] === nothing
end

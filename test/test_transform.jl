module TestTransform
using Test, TOML, UUIDs
import DispatchCheckup
const I = DispatchCheckup._implementation()

_latest(mod, name) = Base.invokelatest(getglobal, mod, name)
_call(mod, name, args...) = Base.invokelatest(_latest(mod, name), args...)

function source_files(ex)
    ex isa LineNumberNode && return ex.file === nothing ? String[] : [String(ex.file)]
    ex isa Expr || return String[]
    return reduce(vcat, source_files.(ex.args); init=String[])
end

function fixture(f; unstable=String[], require_all=false, extra="")
    mktempdir() do root
        original, overlay, snapshot = (joinpath(root, name) for name in ("original", "overlay", "snapshot"))
        foreach(path -> mkpath(joinpath(path,"src")), (original, overlay, snapshot))
        name = Symbol("TransformFixture_" * replace(string(uuid4()), "-"=>""))
        target = "Main." * String(name)
        source = """
        module $name
        foo(x::Bool) = x ? 1 : 1.0
        foo(x::Int) = x > 0 ? 1 : 1.0
        ok(x::Int) = x + 1
        const source_directory = @__DIR__
        const source_file = @__FILE__
        const mapper_calls = Ref(0)
        const mapper_expressions = Any[]
        mapper(ex) = (mapper_calls[] += 1; push!(mapper_expressions, ex); ex)
        include("plain.jl")
        include(mapper, "mapped.jl")
        Base.include(@__MODULE__, "qualified.jl")
        Base.include(mapper, @__MODULE__, "qualified_mapped.jl")
        Base.include_string(@__MODULE__, "string_bad(x::Bool) = x ? 1 : 1.0", "generated_one.jl")
        Base.include_string(mapper, @__MODULE__, "string_mapped_bad(x::Bool) = x ? 1 : 1.0", "generated_two.jl")
        const after_include = plain_ok(2)
        const include_return = include("value.jl")
        const evaluation_order = Symbol[]
        module_argument() = (push!(evaluation_order, :module); @__MODULE__)
        path_argument() = (push!(evaluation_order, :path); "evaluated.jl")
        Base.include(module_argument(), path_argument())
        module Nested
        foo(x::Bool) = x ? 1 : 1.0
        end
        baremodule Bare
        bare_bad(x::Bool) = x ? 1 : 1.0
        end
        $extra
        end
        """
        files = Dict("$(name).jl"=>source,
            "plain.jl"=>"plain_ok(x::Int) = x + 2\n",
            "mapped.jl"=>"\n\n\nmapped_bad(x::Bool) = x ? 1 : 1.0\n",
            "qualified.jl"=>"qualified_bad(x::Bool) = x ? 1 : 1.0\n",
            "qualified_mapped.jl"=>"qualified_mapped_bad(x::Bool) = x ? 1 : 1.0\n",
            "value.jl"=>"40 + 2\n",
            "alias.jl"=>"aliased_bad(x::Bool) = x ? 1 : 1.0\n",
            "evaluated.jl"=>"evaluated_bad(x::Bool) = x ? 1 : 1.0\n")
        for (file, contents) in files
            write(joinpath(original,"src",file), contents)
            write(joinpath(snapshot,"src",file), contents)
        end
        # The snapshot must win even if the original checkout changes afterwards.
        write(joinpath(original,"src","plain.jl"), "error(\"read live original source\")\n")
        config_file = joinpath(root,"config.toml")
        open(config_file,"w") do io
            TOML.print(io, Dict("format_version"=>1, "target_name"=>target,
                "target_uuid"=>string(uuid4()), "original_root"=>original,
                "overlay_root"=>overlay, "snapshot_root"=>snapshot,
                "main_entry"=>joinpath(original,"src","$(name).jl"),
                "unstable"=>unstable, "require_all"=>require_all))
        end
        observer = I.start_include_observer!(config_file)
        try
            I.instrument_entry(Main, config_file, joinpath(original,"src","$(name).jl"))
            mod = _latest(Main, name)
            f(mod, config_file, original, snapshot)
        finally
            I.stop_include_observer!(observer)
        end
    end
end

@testset "Source mapper preserves includes, locations, and identity" begin
    fixture() do mod, config, original, snapshot
        @test _call(mod,:ok,2) == 3
        @test _latest(mod,:after_include) == 4
        @test _latest(mod,:include_return) == 42
        @test _latest(mod,:evaluation_order) == [:module, :path]
        @test _latest(mod,:source_directory) == joinpath(original,"src")
        @test _latest(mod,:source_file) == joinpath(original,"src",String(nameof(mod))*".jl")
        @test _latest(mod,:mapper_calls)[] == 3
        mapper_files = reduce(vcat, source_files.(_latest(mod,:mapper_expressions)); init=String[])
        @test joinpath(original,"src","mapped.jl") in mapper_files
        @test joinpath(original,"src","qualified_mapped.jl") in mapper_files
        @test all(!startswith(file,snapshot) for file in mapper_files)
        for name in (:foo,:mapped_bad,:qualified_bad,:qualified_mapped_bad,:string_bad,:string_mapped_bad,:evaluated_bad)
            @test_throws I.DispatchDoctor.TypeInstabilityError _call(mod,name,true)
        end
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(_latest(mod,:Nested),:foo,true)
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(_latest(mod,:Bare),:bare_bad,true)
        report = I.instrumentation_report(config)
        @test report["counts"]["instrumented"] >= 10
        @test report["counts"]["unsupported"] == 0
        @test any(endswith("plain.jl"),report["files"])
        @test all(!startswith(file,snapshot) for file in report["files"])
        @test only(filter(record -> endswith(record["name"],".mapped_bad"), report["records"]))["line"] == 4
        @test I.validate_exclusions!(config) === nothing
        @test I._validate_include_observations!(I._instrumentation_context(config)) === nothing
    end
end

@testset "Aliased includes fail coverage validation" begin
    for source in ("const loader = include; loader(\"alias.jl\")",
                   "const loader = Base.include; loader(@__MODULE__, \"alias.jl\")",
                   "const loader = include; loader(\"plain.jl\")")
        fixture(; extra=source) do mod, config, _, _
            # The original call retains Julia's ordinary behavior. The observer
            # detects the missing mapper even for a file mapped once before.
            @test_throws r"included source bypassed instrumentation" I._validate_include_observations!(I._instrumentation_context(config))
            report = I.instrumentation_report(config)
            @test any(event -> !event["instrumented"], report["observed_includes"])
        end
    end
end

@testset "First-class include_string loaders fail closed" begin
    for source in (
        "const loader = Base.include_string; loader(@__MODULE__, \"aliased(x)=x\", \"generated_one.jl\")",
        "using Base: include_string; const loader = include_string",
        "const loader = getfield(Base, :include_string)",
        "identity(Base.include_string)")
        @test_throws r"first-class include_string reference" fixture(; extra=source) do _, _, _, _
            error("an include_string alias unexpectedly loaded")
        end
    end
    fixture(; extra="""
        using Base: include_string
        include_string(@__MODULE__, "direct_string(x::Int)=x+1", "direct_string.jl")
        echo_loader(include_string) = include_string
        with_loader_type(x::include_string) where {include_string} = x
        const quoted_loader = :(Base.include_string)
        struct LoaderField
            include_string::Int
        end
        """) do mod, _, _, _
        @test _call(mod,:direct_string,2) == 3
        @test _call(mod,:echo_loader,2) == 2
        @test _call(mod,:with_loader_type,2) == 2
        @test _latest(mod,:quoted_loader) == :(Base.include_string)
        @test fieldnames(_latest(mod,:LoaderField)) == (:include_string,)
    end
end

@testset "Bare exclusions select the root generic and all its methods" begin
    fixture(; unstable=["foo"]) do mod, config, _, _
        @test _call(mod,:foo,true) == 1
        @test _call(mod,:foo,1) == 1
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(_latest(mod,:Nested),:foo,true)
        @test I.validate_exclusions!(config) === nothing
        @test only(values(I.instrumentation_report(config)["exclusions"])) == 2
    end
    fixture(; unstable=["missing"]) do _, config, _, _
        @test_throws r"unmatched unstable exclusions" I.validate_exclusions!(config)
    end
    fixture(; unstable=["callback", "global_callback"], extra="""
        const callback = x -> x > 0 ? 1 : 1.0
        global global_callback = x -> x > 0 ? 1 : 1.0
        """) do mod, config, _, _
        @test _call(mod,:callback,1) == 1
        @test _call(mod,:global_callback,1) == 1
        @test I.validate_exclusions!(config) === nothing
        @test all(==(1), values(I.instrumentation_report(config)["exclusions"]))
    end
    fixture(; unstable=["getindex"], extra="""
        import Base: getindex
        struct RootIndexable; value::Bool; end
        getindex(x::RootIndexable) = x.value ? 1 : 1.0
        module OtherMethods
            import Base: getindex
            struct NestedIndexable; value::Bool; end
            getindex(x::NestedIndexable) = x.value ? 1 : 1.0
        end
        module Unrelated
            getindex(x::Bool) = x ? 1 : 1.0
        end
        """) do mod, config, _, _
        nested = _latest(mod,:OtherMethods)
        value = Base.invokelatest(_latest(nested,:NestedIndexable),true)
        @test Base.invokelatest(getindex,value) == 1
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(_latest(mod,:Unrelated),:getindex,true)
        @test I.validate_exclusions!(config) === nothing
        @test only(values(I.instrumentation_report(config)["exclusions"])) == 2
    end
end

@testset "Native control macros and registered decorators remain supported" begin
    fixture(; unstable=["static_excluded"], extra="""
        @static if VERSION >= v"1.13"
            static_excluded(x::Bool) = x ? 1 : 1.0
            static_checked(x::Bool) = x ? 1 : 1.0
        else
            static_unselected(x::Bool) = x ? 1 : 1.0
        end
        import DispatchDoctor
        macro passthrough(definition)
            esc(definition)
        end
        DispatchDoctor.register_macro!(Symbol("@passthrough"), DispatchDoctor.CompatibleMacro, @__MODULE__)
        @passthrough decorated_bad(x::Bool) = x ? 1 : 1.0
        """) do mod, config, _, _
        @test _call(mod,:static_excluded,true) == 1
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(mod,:static_checked,true)
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(mod,:decorated_bad,true)
        @test !isdefined(mod,:static_unselected)
        @test I.validate_exclusions!(config) === nothing
        @test !any(record -> endswith(record["name"],".static_unselected"), I.instrumentation_report(config)["records"])
    end
    fixture(; extra="""
        import Distributed
        Distributed.@everywhere [Distributed.myid()] everywhere_checked(x::Bool) = x ? 1 : 1.0
        """) do _, config, _, _
        @test_throws I.DispatchDoctor.TypeInstabilityError _call(Main,:everywhere_checked,true)
        @test any(record -> record["kind"] == "instrumented" && endswith(record["name"],".everywhere_checked"), I.instrumentation_report(config)["records"])
    end
end

@testset "Unsupported definitions are visible" begin
    fixture(; extra="@generated generated_bad(x) = :(x)") do mod, config, _, _
        @test _call(mod,:generated_bad,2) == 2
        report = I.instrumentation_report(config)
        @test any(record -> record["kind"] == "unsupported" && occursin("@generated",record["reason"]), report["records"])
    end
    fixture(; unstable=["generated_one"], extra="""
        @eval begin
            generated_one(x::Bool) = x ? 1 : 1.0
            generated_two(x::Bool) = x ? 1 : 1.0
        end
        """) do mod, config, _, _
        @test _call(mod,:generated_one,true) == 1
        @test _call(mod,:generated_two,true) == 1
        @test I.validate_exclusions!(config) === nothing
        records = I.instrumentation_report(config)["records"]
        @test any(record -> record["kind"] == "excluded" && endswith(record["name"],".generated_one"), records)
        @test any(record -> record["kind"] == "unsupported" && endswith(record["name"],".generated_two"), records)
    end
    fixture(; unstable=["factory"], extra="factory(offset) = x -> x + offset") do mod, config, _, _
        @test Base.invokelatest(_call(mod,:factory,2),3) == 5
        @test I.validate_exclusions!(config) === nothing
        @test I.instrumentation_report(config)["counts"]["unsupported"] == 0
    end
    fixture(; unstable=["Container"], extra="""
        struct Container{T}
            value::T
            Container{T}(value) where {T} = new{T}(value)
        end
        """) do mod, config, _, _
        @test I.validate_exclusions!(config) === nothing
        records = I.instrumentation_report(config)["records"]
        @test any(record -> record["kind"] == "excluded" && endswith(record["name"],".Container"), records)
    end
end

@testset "Literal macros and empty generics do not create coverage gaps" begin
    fixture(; require_all=true, extra="""
        function extension_value end
        @static if VERSION >= v"1.13"
            literal_branch(x::Int) = x + 1
        end
        const base_literals = (v"1.13", r"value", s"value", b"value", raw"value",
                               big"42", MIME"text/plain", html"value", text"value")
        """) do mod, config, _, _
        @test isempty(methods(_latest(mod,:extension_value)))
        @test _call(mod,:literal_branch,2) == 3
        @test first(_latest(mod,:base_literals)) == v"1.13"
        @test I.instrumentation_report(config)["counts"]["unsupported"] == 0
        @test I._validate_coverage_policy!(I._instrumentation_context(config)) === nothing
    end
    fixture(; require_all=true, extra="""
        macro v_str(value)
            value
        end
        const custom_literal = v"custom"
        """) do mod, config, _, _
        @test _latest(mod,:custom_literal) == "custom"
        @test any(record -> occursin("opaque macro @v_str",record["reason"]), I.instrumentation_report(config)["records"])
        @test_throws r"unsupported definitions remain" I._validate_coverage_policy!(I._instrumentation_context(config))
    end
end

@testset "Include declarations retain their signatures" begin
    fixture() do _, config, original, _
        ctx = I._instrumentation_context(config)
        source = :(function Base.include(mod::Module, path::String)
            path
        end)
        transformed = I._rewrite_calls(ctx, source, ctx.target, joinpath(original,"src","declaration.jl"), 1)
        @test transformed.args[1] == source.args[1]
        source = :(include(path::String) = path)
        transformed = I._rewrite_calls(ctx, source, ctx.target, joinpath(original,"src","declaration.jl"), 1)
        @test transformed.args[1] == source.args[1]
        source = :(with_default(value=include("value.jl")) = value)
        transformed = I._rewrite_calls(ctx, source, ctx.target, joinpath(original,"src","declaration.jl"), 1)
        @test transformed.args[1].args[1] === :with_default
        @test transformed.args[1].args[2] != source.args[1].args[2]
    end
end

@testset "Included source cannot escape the snapshot" begin
    fixture() do _, config, original, _
        ctx = I._instrumentation_context(config)
        @test_throws r"escapes the instrumented package" I._snapshot_path(ctx, joinpath(dirname(original),"other.jl"))
        @test_throws r"absent from the snapshot" I._snapshot_path(ctx,joinpath(original,"src","missing.jl"))
    end
end
end

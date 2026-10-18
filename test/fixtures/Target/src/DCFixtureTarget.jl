module DCFixtureTarget

using DCFixtureDependency: DCFixtureDependency, Token

stable(x::Int) = x + 1
token(x::Int) = Token(x)
foo(x::Int) = x > 0 ? x : Float64(x)
foo(x::Int32) = x > 0 ? x : Float32(x)
bar(x::Int) = x > 0 ? x : Float64(x)
root_unstable(x::Int) = x > 0 ? x : Float64(x)

@static if VERSION >= v"1.13"
    static_unstable(x::Int) = x > 0 ? x : Float64(x)
else
    static_unstable(x::Int) = x
end

const map_hits = Int[]
record_map(expression) = (push!(map_hits, 1); expression)

include("bare.jl")
include(record_map, "mapped.jl")
Base.include(@__MODULE__, joinpath(@__DIR__, "qualified.jl"))
Base.include(record_map, @__MODULE__, joinpath(@__DIR__, "base_mapped.jl"))
include(joinpath(@__DIR__, "dynamic.jl"))
Base.include_string(@__MODULE__,
    "string_unstable(x::Int) = x > 0 ? x : Float64(x)",
    joinpath(@__DIR__, "inline_fixture.jl"))
Base.include_string(record_map, @__MODULE__,
    "mapped_string_unstable(x::Int) = x > 0 ? x : Float64(x)",
    joinpath(@__DIR__, "mapped_inline_fixture.jl"))

module Nested
    stable(x::Int) = x + 2
    foo(x::Int) = x > 0 ? x : Float64(x)
    nested_unstable(x::Int) = x > 0 ? x : Float64(x)
    include("nested.jl")
end

baremodule BareNested
    using Base
    stable(x::Int) = x + 3
    baremodule_unstable(x::Int) = x > 0 ? x : Float64(x)
end

function extension_value end

end

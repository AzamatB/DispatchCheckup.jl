using Test

# `Pkg.test(test_args = ["test_gpu.jl"])` runs a selection. The files mostly wait for Julia
# processes of their own, so they run side by side, those that start processes first.
const TEST_FILES = ["test_integration.jl", "test_gpu.jl", "test_layouts.jl", "test_transform.jl",
                    "test_quality.jl"]
const SELECTED = isempty(ARGS) ? TEST_FILES : ARGS
all(in(TEST_FILES), SELECTED) || error("Unknown test selection: $ARGS")

include(joinpath(@__DIR__, "support.jl"))

@testset "DispatchCheckup" begin
    @sync for file in SELECTED
        @async @testset "$file" include(joinpath(@__DIR__, file))
    end
end

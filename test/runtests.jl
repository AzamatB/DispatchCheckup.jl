using Test

const TEST_FILES = ["test_transform.jl", "test_integration.jl", "test_original.jl", "test_layouts.jl",
                    "test_aqua.jl", "test_check_concrete_structs.jl", "test_gpu.jl"]
const DEFAULT_TEST_FILES = get(ENV, "DISPATCHCHECKUP_GPU_TESTS", "0") == "1" ?
    TEST_FILES : filter(!=("test_gpu.jl"), TEST_FILES)
const TEST_SELECTED = isempty(ARGS) ? DEFAULT_TEST_FILES : ARGS
all(in(TEST_FILES), TEST_SELECTED) || error("Unknown test selection: $ARGS")

for file in TEST_SELECTED
    include(file)
end

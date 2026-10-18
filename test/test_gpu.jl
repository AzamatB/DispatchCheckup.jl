using Test

get(ENV, "DISPATCHCHECKUP_GPU_TESTS", "0") == "1" ||
    error("Native GPU qualification requires DISPATCHCHECKUP_GPU_TESTS=1 and the test/gpu environment")

using CUDA
isdefined(@__MODULE__, :DispatchCheckupFixtures) || include("fixtures/support.jl")
const DCGPUF = DispatchCheckupFixtures

const GPU_STABLE_BODY = raw"""
using Test, CUDA, DCFixtureGPU
@test CUDA.functional()
println("DCT_GPU_DEVICE=", CUDA.name(CUDA.device()))
println("DCT_GPU_RUNTIME=", CUDA.runtime_version())
println("DCT_GPU_TARGET=", pkgdir(DCFixtureGPU))
input = CuArray(Float32[-2, -1, 0, 1, 2])
output = similar(input)
CUDA.@sync @cuda threads=32 DCFixtureGPU.stable_kernel!(output, input)
@test Array(output) == Float32[-4, -2, 0, 2, 4]
wide_output = CUDA.zeros(Float64, 1)
wide_args = ntuple(Float64, 36)
CUDA.@sync @cuda threads=1 DCFixtureGPU.wide_kernel!(wide_output, wide_args...)
@test only(Array(wide_output)) == 37.0
CUDA.@sync @cuda threads=1 DCFixtureGPU.override_kernel!(wide_output, 3.0, 7.0)
@test only(Array(wide_output)) == 21.0
typed_output = CUDA.zeros(Float64, 3)
typed_x = CUDA.ones(Float64, 3)
typed_matrix = CUDA.ones(Float64, 6, 3)
typed_indices = CUDA.ones(Int32, 4)
CUDA.@sync @cuda threads=3 DCFixtureGPU.typed_val_kernel!(typed_output, typed_x,
    typed_matrix, typed_matrix, typed_output, typed_indices, typed_matrix,
    typed_indices, typed_indices, typed_indices, typed_x, Int32(3), Val(true), Val(false))
@test Array(typed_output) == fill(2.0, 3)
"""

@testset "DispatchCheckup native CUDA qualification" begin
    @test CUDA.functional()
    @info "Native CUDA qualification" device=CUDA.name(CUDA.device()) runtime=CUDA.runtime_version()
    DCGPUF.with_sandbox(; gpu=true) do sandbox
        control = DCGPUF.run_script(sandbox, "gpu-ordinary", GPU_STABLE_BODY * raw"""
            integers = CuArray(Int32[-2, -1, 0, 1, 2])
            CUDA.@sync @cuda threads=32 DCFixtureGPU.unstable_kernel!(output, integers)
            @test Array(output) == Float32[-2, -1, 0, 1, 2]
            @test !fixture_loaded("DispatchDoctor")
            """; target=:DCFixtureGPU, active=false)
        control.code == 0 || @error "ordinary GPU fixture failed" output=control.output
        @test control.code == 0
        @test control.originals_unchanged

        guarded = DCGPUF.run_script(sandbox, "gpu-instrumented", GPU_STABLE_BODY * raw"""
            host_failure = try
                DCFixtureGPU.unstable_device(Int32(1))
            catch exception
                exception
            end
            @test nameof(typeof(host_failure)) === :TypeInstabilityError
            integers = CuArray(Int32[-2, -1, 0, 1, 2])
            device_failure = try
                CUDA.@sync @cuda threads=32 DCFixtureGPU.unstable_kernel!(output, integers)
                nothing
            catch exception
                exception
            end
            # DispatchDoctor's deliberate error path is not valid device IR.
            # This is a compile-time failure, not an on-device TypeInstabilityError.
            @test nameof(typeof(device_failure)) === :InvalidIRError
            println("DCT_GPU_FAILURE=", nameof(typeof(device_failure)))
            """; target=:DCFixtureGPU)
        guarded.code == 0 || @error "instrumented GPU fixture failed" output=guarded.output
        @test guarded.code == 0
        @test guarded.originals_unchanged
        @test occursin("DCT_GPU_FAILURE=InvalidIRError", guarded.output)

        excluded = DCGPUF.run_script(sandbox, "gpu-excluded-helper", GPU_STABLE_BODY * raw"""
            integers = CuArray(Int32[-2, -1, 0, 1, 2])
            CUDA.@sync @cuda threads=32 DCFixtureGPU.unstable_kernel!(output, integers)
            @test Array(output) == Float32[-2, -1, 0, 1, 2]
            @test DCFixtureGPU.unstable_device(Int32(1)) === Int32(1)
            println("DCT_GPU_EXCLUSION_OK")
            """; target=:DCFixtureGPU, unstable=(:unstable_device,))
        excluded.code == 0 || @error "excluded GPU helper fixture failed" output=excluded.output
        @test excluded.code == 0
        @test excluded.originals_unchanged
        @test occursin("DCT_GPU_EXCLUSION_OK", excluded.output)
        for result in (guarded, excluded)
            @test count(==("DCT_BODY_COMPLETE"), split(result.output, '\n')) == 1
            for path in DCGPUF.printed_paths(result, "DCT_ACTIVE_PROJECT")
                @test !ispath(dirname(path))
            end
            for path in DCGPUF.printed_paths(result, "DCT_GPU_TARGET")
                @test path != sandbox.packages["DCFixtureGPU"]
                @test !ispath(path)
            end
        end
        @info "Native CUDA fixture results" ordinary=control.code instrumented=guarded.code excluded=excluded.code
    end
end

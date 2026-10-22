# Manual tier: checked runs of a CUDA package (needs a GPU and the test/gpu environment):
#   julia --project=test/gpu -e 'using Pkg; Pkg.instantiate()'
#   DISPATCHCHECKUP_GPU_TESTS=1 julia --project=test/gpu test/runtests.jl test_gpu.jl
using Test

get(ENV, "DISPATCHCHECKUP_GPU_TESTS", "0") == "1" ||
    error("the CUDA tests need DISPATCHCHECKUP_GPU_TESTS=1 and the test/gpu environment")

using CUDA
isdefined(@__MODULE__, :Fixtures) || include("support.jl")
using .Fixtures: CHECKUP, Fixtures, UUIDS, julia, package_project, resolve, write_files

const GPU_FIXTURE = Dict(
    "Project.toml" => package_project("DCFixtureGPU"; deps = Dict("CUDA" => UUIDS["CUDA"])),
    "src/DCFixtureGPU.jl" => """
        module DCFixtureGPU

        using CUDA

        stable_device(x::Float32) = x + x
        unstable_device(x::Int32) = x > Int32(0) ? x : Float32(x)

        function stable_kernel!(output, input)
            index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
            if index <= length(output)
                @inbounds output[index] = stable_device(input[index])
            end
            return nothing
        end

        function unstable_kernel!(output, input)
            index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
            if index <= length(output)
                @inbounds output[index] = Float32(unstable_device(input[index]))
            end
            return nothing
        end

        # A wide argument list must not need a host-side tuple in the check.
        function wide_kernel!(output, $(join(("x$i" for i in 1:36), ", ")))
            output[1] = x1 + x36
            return nothing
        end

        @inline override_product(x::Float64, y::Float64) = x * y
        CUDA.@device_override @noinline override_product(x::Float64, y::Float64) = x * y

        function override_kernel!(output, x, y)
            output[1] = override_product(x, y)
            return nothing
        end

        function typed_val_kernel!(out, x, off, nc, ::Val{HAS_X}) where {HAS_X}
            index = (blockIdx().x - Int32(1)) * blockDim().x + threadIdx().x
            if index <= nc
                @inbounds out[index] = x[index] + (HAS_X ? off[1, index] : 0.0)
            end
            return nothing
        end

        end
        """)

const GPU_BODY = """
    @test CUDA.functional()
    println("DCT_GPU_DEVICE=", CUDA.name(CUDA.device()))
    @test pkgdir(DCFixtureGPU) == ENV["DCT_ROOT"]
    input = CuArray(Float32[-2, -1, 0, 1, 2])
    output = similar(input)
    CUDA.@sync @cuda threads=32 DCFixtureGPU.stable_kernel!(output, input)
    @test Array(output) == Float32[-4, -2, 0, 2, 4]
    wide = CUDA.zeros(Float64, 1)
    CUDA.@sync @cuda threads=1 DCFixtureGPU.wide_kernel!(wide, ntuple(Float64, 36)...)
    @test only(Array(wide)) == 37.0
    CUDA.@sync @cuda threads=1 DCFixtureGPU.override_kernel!(wide, 3.0, 7.0)
    @test only(Array(wide)) == 21.0
    typed = CUDA.zeros(Float64, 3)
    CUDA.@sync @cuda threads=3 DCFixtureGPU.typed_val_kernel!(typed, CUDA.ones(Float64, 3),
        CUDA.ones(Float64, 6, 3), Int32(3), Val(true))
    @test Array(typed) == fill(2.0, 3)
    integers = CuArray(Int32[-2, -1, 0, 1, 2])
    """

# DispatchDoctor applies `CUDA.@device_override` to its inferred copy of the function too,
# which cannot work, so that definition is excluded by its line.
const OVERRIDE = findfirst(startswith("CUDA.@device_override"), split(GPU_FIXTURE["src/DCFixtureGPU.jl"], '\n'))
const UNSTABLE_OVERRIDE = ":override_product => \"src/DCFixtureGPU.jl:$OVERRIDE\""

gpu_script(body; activate = true, options = "unstable = $UNSTABLE_OVERRIDE") = """
    $(activate ? "" : "# ")import DispatchCheckup
    $(activate ? "" : "# ")DispatchCheckup.dispatch_doctor(:DCFixtureGPU$(isempty(options) ? "" : "; $options"))
    using Test, CUDA, DCFixtureGPU
    @testset "GPU" begin
    $GPU_BODY
    $body
    end
    """

@testset "DispatchCheckup with CUDA" begin
    @test CUDA.functional()
    mktempdir() do sandbox
        package = write_files(joinpath(sandbox, "DCFixtureGPU"), GPU_FIXTURE)
        env = joinpath(sandbox, "env")
        # The test/gpu manifest (absolute paths), plus the fixture package.
        project = something(Base.active_project())
        manifest = Fixtures.TOML.parsefile(something(Base.project_file_manifest_path(project)))
        for records in values(manifest["deps"]), record in records
            haskey(record, "path") && (record["path"] = normpath(dirname(project), record["path"]))
        end
        write_files(env, Dict("Manifest.toml" => manifest, "Project.toml" => Dict(
            "deps" => Dict(n => UUIDS[n] for n in ("CUDA", "DispatchCheckup", "Test", "DCFixtureGPU")),
            "sources" => Dict("DispatchCheckup" => Dict("path" => CHECKUP),
                              "DCFixtureGPU" => Dict("path" => package)))))
        resolve(env)
        run_gpu(name, text) = (write(joinpath(env, "$name.jl"), text);
            julia("--project=$env", joinpath(env, "$name.jl"); dir = env, env = Dict("DCT_ROOT" => package)))

        ordinary = run_gpu("ordinary", gpu_script("""
            CUDA.@sync @cuda threads=32 DCFixtureGPU.unstable_kernel!(output, integers)
            @test Array(output) == Float32[-2, -1, 0, 1, 2]
            @test !any(id -> id.name == "DispatchDoctor", keys(Base.loaded_modules))
            """; activate = false))
        ordinary.code == 0 || println(ordinary.output)
        @test ordinary.code == 0

        checked = run_gpu("checked", gpu_script("""
            @test_throws DispatchCheckup.DispatchDoctor.TypeInstabilityError DCFixtureGPU.unstable_device(Int32(1))
            # The check's error path is not valid device code, so the kernel fails to compile.
            failure = try
                CUDA.@sync @cuda threads=32 DCFixtureGPU.unstable_kernel!(output, integers)
                nothing
            catch exception
                exception
            end
            @test nameof(typeof(failure)) === :InvalidIRError
            """))
        checked.code == 0 || println(checked.output)
        @test checked.code == 0

        excluded = run_gpu("excluded", gpu_script("""
            CUDA.@sync @cuda threads=32 DCFixtureGPU.unstable_kernel!(output, integers)
            @test Array(output) == Float32[-2, -1, 0, 1, 2]
            @test DCFixtureGPU.unstable_device(Int32(1)) === Int32(1)
            """; options = "unstable = (:unstable_device, $UNSTABLE_OVERRIDE)"))
        excluded.code == 0 || println(excluded.output)
        @test excluded.code == 0
        @info "CUDA fixture results" ordinary.code checked.code excluded.code
        Fixtures.remove_overlays("DCFixtureGPU")
    end
end

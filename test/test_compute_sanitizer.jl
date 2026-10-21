# Run with --project=test/gpu after environment preparation and a baseline run.
# Activation is in-process; there is no Pkg operation, child test process, or invalid GPU kernel here.
using Test, CUDA
import DispatchCheckup as DC

VERSION >= v"1.13" || error("Julia 1.13 or later is required")
realpath(pkgdir(DC)) == realpath(joinpath(@__DIR__, "..")) || error("wrong DispatchCheckup checkout")
CUDA.functional() || error("Compute Sanitizer workload requires a functional CUDA device")
CUDA.allowscalar(false)

const FIXTURE_ROOT = realpath(joinpath(@__DIR__, "sanitizer_fixture"))
const FIXTURE_ENTRY = joinpath(FIXTURE_ROOT, "src", "DCSanitizerFixture.jl")
const FIXTURE_PROJECT = joinpath(FIXTURE_ROOT, "Project.toml")
const SOURCE_BEFORE = (read(FIXTURE_ENTRY), read(FIXTURE_PROJECT))
const OVERRIDE_LINE = something(findfirst(startswith("CUDA.@device_override"), readlines(FIXTURE_ENTRY)))

# Only the device override definition is excluded. Its ordinary host definition
# and all four fixture kernels still pass through the checked overlay.
DC.dispatch_doctor(:DCSanitizerFixture;
    unstable = (:override_product => "src/DCSanitizerFixture.jl:$OVERRIDE_LINE",))
using DCSanitizerFixture

println("COMPUTE_SANITIZER_WORKLOAD_BEGIN DispatchCheckup")
@testset "checked overlay provenance" begin
    activation = something(DC.ACTIVE[])
    id = Base.PkgId(DCSanitizerFixture)
    @test ENV["DISPATCH_CHECKUP"] == "checked"
    @test activation.config.id == id && id in activation.loaded
    @test isempty(activation.failures) && isempty(activation.original)
    @test DC.LOADED_FROM[id] == activation.shims[id]
    @test realpath(pkgdir(DCSanitizerFixture)) == FIXTURE_ROOT
    @test realpath(pathof(DCSanitizerFixture)) == FIXTURE_ENTRY
    @test isdefined(DCSanitizerFixture, Symbol("#DispatchCheckup"))
    @test length(activation.config.unstable) == 1
end

@testset "checked GPU methods" begin
    n = 259
    host = Float32.(collect(-129:129))
    input = CuArray(host); output = similar(input)
    CUDA.@cuda threads=128 blocks=cld(n,128) DCSanitizerFixture.stable_kernel!(output,input)
    CUDA.synchronize()
    @test Array(output) == 2f0 .* host

    wide = CuArray{Float64}(undef, 1)
    CUDA.@cuda threads=1 DCSanitizerFixture.wide_kernel!(wide, ntuple(Float64,36)...)
    CUDA.synchronize()
    @test only(Array(wide)) == 37.0

    CUDA.@cuda threads=1 DCSanitizerFixture.override_kernel!(wide, 3.0, 7.0)
    CUDA.synchronize()
    @test only(Array(wide)) == 21.0

    xh = [0.25 + i/8 for i in 1:n]
    offsets = reshape([mod(i,7)/16 for i in 1:6n], 6,n)
    x = CuArray(xh); offset = CuArray(offsets); out = similar(x)
    CUDA.@cuda threads=128 blocks=cld(n,128) DCSanitizerFixture.typed_val_kernel!(out,x,offset,Int32(n),Val(true))
    CUDA.synchronize()
    @test Array(out) == xh + offsets[1,:]
    # The false specialization must not read its deliberately empty offset.
    CUDA.@cuda threads=128 blocks=cld(n,128) DCSanitizerFixture.typed_val_kernel!(out,x,CUDA.zeros(Float64,0,0),Int32(n),Val(false))
    CUDA.synchronize()
    @test Array(out) == xh
end

@testset "source bytes remain unchanged" begin
    @test (read(FIXTURE_ENTRY), read(FIXTURE_PROJECT)) == SOURCE_BEFORE
    @test isempty(something(DC.ACTIVE[]).failures)
end
CUDA.synchronize()
println("COMPUTE_SANITIZER_WORKLOAD_COMPLETE DispatchCheckup")

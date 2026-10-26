using Test, Aqua
using CheckConcreteStructs: all_concrete
import DispatchCheckup

@testset "Aqua" begin
    Aqua.test_all(DispatchCheckup)
end

@testset "Concrete struct fields" begin
    @test all_concrete(DispatchCheckup; verbose = true)
end

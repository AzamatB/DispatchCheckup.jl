using Test
using CheckConcreteStructs: all_concrete
import DispatchCheckup

@testset "Concrete struct fields" begin
    @test all_concrete(DispatchCheckup; verbose = true)
end

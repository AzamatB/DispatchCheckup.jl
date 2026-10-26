# Aqua's checks and the concrete struct fields of DispatchCheckup.
@testitem "Aqua" begin
    using Aqua
    Aqua.test_all(DispatchCheckup)
end

@testitem "Concrete struct fields" begin
    using CheckConcreteStructs: all_concrete
    @test all_concrete(DispatchCheckup; verbose = true)
end

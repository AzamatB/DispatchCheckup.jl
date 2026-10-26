# Aqua's checks and the concrete struct fields of DispatchCheckup.

# Aqua.test_all, as three items: its two checks that start Julia processes of their own run beside the rest.
@testitem "Aqua" begin
    using Aqua
    Aqua.test_all(DispatchCheckup; ambiguities = false, persistent_tasks = false)
end

@testitem "Aqua method ambiguities" begin
    using Aqua
    Aqua.test_ambiguities([DispatchCheckup])
end

@testitem "Aqua persistent tasks" begin
    using Aqua
    Aqua.test_persistent_tasks(DispatchCheckup)
end

@testitem "Concrete struct fields" begin
    using CheckConcreteStructs: all_concrete
    @test all_concrete(DispatchCheckup; verbose = true)
end

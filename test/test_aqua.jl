using Test
using Aqua
import DispatchCheckup

@testset "Aqua" begin
    Aqua.test_all(DispatchCheckup)
end

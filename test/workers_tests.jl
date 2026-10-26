# The workers run as the main process does: with --depwarn=error and its bounds checking (Base.julia_cmd forwards
# them, also to the fixture processes the items start), and with the work tree's DispatchCheckup, unchecked: this
# suite does not check DispatchCheckup itself (integration_tests.jl checks that a checked run's workers are checked).
# runtests.jl hands each worker the main process's settings.
@testitem "workers: the main process's flags and package" begin
    @test Base.JLOptions().depwarn == 2
    @test Base.JLOptions().depwarn == Main.MAIN_DEPWARN
    @test Base.JLOptions().check_bounds == 1   # --check-bounds=yes, which Pkg.test passes
    @test Base.JLOptions().check_bounds == Main.MAIN_CHECK_BOUNDS
    @test pathof(DispatchCheckup) == Main.MAIN_PATHOF
    @test !haskey(ENV, "DISPATCH_CHECKUP") && !isdefined(DispatchCheckup, Symbol("#DispatchCheckup"))
end

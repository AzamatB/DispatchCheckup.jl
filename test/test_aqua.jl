using Test
using Aqua
import DispatchCheckup

@testset "Aqua" begin
    # Importing the package must not load its checking machinery. Aqua's stale
    # dependency heuristic only observes import time, so these intentional lazy
    # dependencies need an explicit list. Integration tests prove that activation
    # loads the machinery while the commented-out call leaves it unloaded.
    lazy_dependencies = [:DispatchDoctor, :MacroTools, :Pkg, :Preferences, :SHA, :TOML, :UUIDs]
    Aqua.test_all(DispatchCheckup; stale_deps=(ignore=lazy_dependencies,))

    # Aqua's isolated ambiguity subprocess sees the intentionally inert import.
    # Check the loaded implementation as well, without activating any test run.
    DispatchCheckup._implementation()
    @test isempty(Test.detect_ambiguities(DispatchCheckup; recursive=true))
    Aqua.test_unbound_args(DispatchCheckup)
    Aqua.test_piracies(DispatchCheckup)
    @test all(name -> any(id -> id.name == String(name), keys(Base.loaded_modules)), lazy_dependencies)
end

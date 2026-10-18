using Test
using CheckConcreteStructs: all_concrete
import DispatchCheckup

@testset "Concrete struct fields" begin
    implementation = DispatchCheckup._implementation()
    modules = Module[DispatchCheckup, implementation]
    seen = Set{Module}()
    for mod in modules
        mod in seen && continue
        push!(seen, mod)
        @test all_concrete(mod; verbose=true)
        for name in names(mod; all=true, imported=false)
            isdefined(mod, name) || continue
            Base.isdeprecated(mod, name) && continue
            child = getglobal(mod, name)
            child isa Module && child !== mod && parentmodule(child) === mod && push!(modules, child)
        end
    end
end

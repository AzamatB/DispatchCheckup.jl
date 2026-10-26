# The original= process: it runs alongside the checked suite, with the environment from
# activation; its output follows the suite's in one block, even when it crashes; its status
# folds into the run's; and it dies with a suite killed by a signal. Each item runs its fixture
# scripts side by side, in the environment the setup Concurrent makes once per run.
@testsetup module Concurrent
using Test
include(joinpath(@__DIR__, "support.jl"))
using .Fixtures: CHECKUP, Fixtures, UUIDS, resolve, write_files

const CONCURRENT_UUID = "ea2aad5a-4c36-4511-bdf5-e1005ec8d914"

# Marker files in the run's own directory, shared by the suite and its guard process.
const PRELUDE = """
    marker(name) = joinpath(ENV["DCT_MARKERS"], name)
    await(name; timeout = 300) = timedwait(() -> isfile(marker(name)), timeout; pollint = 0.1) === :ok
    """
activation(options) = "import DispatchCheckup\nDispatchCheckup.dispatch_doctor(:DCConcurrent; $options)\n" *
                      "using Test, DCConcurrent\n" * PRELUDE

const SCRIPTS = Dict(
    # Each waits for the other: an implementation that starts the guards after the suite fails.
    "overlap.jl" => activation("original = \"guard_overlap.jl\"") * """
        ENV["DCT_LATE"] = "set"  # (after activation: the guard process does not see it)
        @testset "overlap" begin
            # the same call again starts no second process
            @test DispatchCheckup.dispatch_doctor(:DCConcurrent; original = "guard_overlap.jl") === nothing
            touch(marker("suite"))
            @test await("guard"; timeout = 120) && await("guard_printed")
            println("DCT_SUITE_AFTER")
            # a nested checked run, with its own options and no original=, starts no process
            nested = read(`\$(Base.julia_cmd()) --project=\$(Base.active_project()) nested.jl`, String)
            @test occursin("DCT_NESTED true 1", nested)
            @test_throws DispatchCheckup.DispatchDoctor.TypeInstabilityError DCConcurrent.unstable(1)
        end
        """,
    "guard_overlap.jl" => PRELUDE * """
        touch(marker("guard"))
        using Test, DCConcurrent
        @test await("suite")
        (println("DCT_GUARD_LINE 1"); flush(stdout))
        (println(stderr, "DCT_GUARD_ERR"); flush(stderr))
        (println("DCT_GUARD_LINE 2"); flush(stdout))
        touch(marker("guard_printed"))
        @test DCConcurrent.unstable(1) == 1  # (the ordinary package)
        @test !haskey(ENV, "DCT_LATE")
        @test !any(startswith("DISPATCH_CHECKUP"), keys(ENV))
        """,
    "nested.jl" => """
        import DispatchCheckup
        DispatchCheckup.dispatch_doctor(:DCConcurrent; unstable = :unstable)
        using DCConcurrent
        println("DCT_NESTED ", DispatchCheckup.ACTIVE[].guard === nothing, " ", DCConcurrent.unstable(1))
        """,
    # The status is the first nonzero one of the suite, the checks and the guards.
    "guard_exits.jl" => activation("original = \"guard_five.jl\""),
    "guard_five.jl" => "exit(5)\n",
    "suite_exits.jl" => activation("original = \"guard_fail.jl\"") * "exit(3)\n",
    "guard_fail.jl" => "using Test\n@test 1 == 2\n",
    "guard_killed.jl" => activation("original = \"guard_kill.jl\""),
    "guard_kill.jl" => """
        println("DCT_KILL_OUT")
        ccall(:kill, Cint, (Cint, Cint), getpid(), Base.SIGKILL)
        sleep(60)
        """,
    # A guard process that crashes keeps what it printed (none of it flushed).
    "guard_crashed.jl" => activation("original = \"guard_crash.jl\""),
    "guard_crash.jl" => """
        println("DCT_CRASH_OUT 1")
        println(stderr, "DCT_CRASH_ERR")
        @info "DCT_CRASH_INFO"
        println("DCT_CRASH_OUT 2")
        ccall(:abort, Cvoid, ())
        """,
    # A suite killed by a signal kills the guard process instead of waiting for it.
    "suite_killed.jl" => activation("original = \"guard_beat.jl\"") * """
        await("beat") || exit(7)
        ccall(:kill, Cint, (Cint, Cint), getpid(), Base.SIGTERM)
        sleep(60)
        """,
    # On Linux, so does a suite killed with SIGKILL, which runs no exit hook.
    "suite_sigkilled.jl" => activation("original = \"guard_beat.jl\"") * """
        await("beat") || exit(7)
        ccall(:kill, Cint, (Cint, Cint), getpid(), Base.SIGKILL)
        sleep(60)
        """,
    "guard_beat.jl" => PRELUDE * """
        for i in 1:3000  # (ten minutes: only a kill ends it in time)
            write(marker("beat"), string(i))
            sleep(0.2)
        end
        touch(marker("survived"))
        """,
    # concurrent = false: the guards run after the suite, with the environment at exit (as before).
    "sequential.jl" => activation("original = \"guard_after.jl\", concurrent = false") * """
        println("DCT_SEQUENTIAL ", DispatchCheckup.ACTIVE[].guard === nothing)
        ENV["DCT_LATE"] = "set"
        touch(marker("suite_done"))
        """,
    "guard_after.jl" => PRELUDE * """
        using Test
        @test isfile(marker("suite_done"))
        @test get(ENV, "DCT_LATE", "") == "set"
        @test !any(startswith("DISPATCH_CHECKUP"), keys(ENV))
        println("DCT_AFTER")
        """,
    # A guard process that cannot start fails the run.
    "unstartable.jl" => """
        import DispatchCheckup
        @eval Base.Sys BINDIR = "/nonexistent"
        DispatchCheckup.dispatch_doctor(:DCConcurrent; original = "guard_five.jl")
        println("DCT_BODY_RAN")
        """,
    # ... or, with concurrent = false, at exit.
    "sequential_unstartable.jl" => activation("original = \"guard_five.jl\", concurrent = false") * """
        @eval Base.Sys BINDIR = "/nonexistent"
        println("DCT_BODY_RAN")
        """,
    # An error while waiting for the guard process, or while printing its output, fails the run.
    "join_fails.jl" => activation("original = \"guard_pass.jl\"") *
                       "rm(DispatchCheckup.ACTIVE[].guard.log)\n",
    "guard_pass.jl" => "using Test\n@test true\n",
)

# Run `script` in `env` with a clean load path and its own marker directory, and with `depot` first in
# its depot path (see `Fixtures.depot_path`): what it compiles, and the overlays it writes, stay there.
function run_fixture(env::String, script::String; depot::String, timeout = 600)
    markers = mktempdir(env)
    variables = filter(p -> !startswith(first(p), "DISPATCH_CHECKUP") &&
                            first(p) ∉ ("JULIA_PROJECT", "JULIA_LOAD_PATH"), copy(ENV))
    merge!(variables, Dict("JULIA_LOAD_PATH" => "@:@stdlib", "DCT_MARKERS" => markers,
                           "JULIA_DEPOT_PATH" => Fixtures.depot_path(depot)))
    command = setenv(`$(Base.julia_cmd()) --startup-file=no --project=$env $script`, variables; dir = env)
    log = tempname()
    process = open(io -> run(pipeline(ignorestatus(command); stdout = io, stderr = io); wait = false),
                   log, "w")
    timed_out = timedwait(() -> process_exited(process), timeout) === :timed_out
    timed_out && (kill(process, Base.SIGKILL); wait(process))
    output = read(log, String)
    rm(log)
    return (; code = process.exitcode, signal = process.termsignal, timed_out, output, markers)
end

lines(output) = [line for line in split(output, '\n') if startswith(line, "DCT_")]

show_failure(result, expected = 0) = (result.code == expected || println(result.output); result)

# DCConcurrent and the environment `env` with the scripts, in the main process's scratch directory. The items share
# them: the first worker to get here makes them, and the others wait for it.
const sandbox = joinpath(Main.MAIN_SCRATCH, "original")
const env = joinpath(sandbox, "env")
const made, failed = joinpath(Main.MAIN_SCRATCH, "original.made"), joinpath(Main.MAIN_SCRATCH, "original.failed")
function make_sandbox()
    write_files(joinpath(sandbox, "DCConcurrent"), Dict(
        "Project.toml" => Dict("name" => "DCConcurrent", "uuid" => CONCURRENT_UUID, "version" => "0.1.0"),
        "src/DCConcurrent.jl" => "module DCConcurrent\nunstable(x) = x > 0 ? x : 0.0\nend\n"))
    write_files(env, merge(SCRIPTS, Dict("Project.toml" => Dict(
        "deps" => Dict("DCConcurrent" => CONCURRENT_UUID, "DispatchCheckup" => UUIDS["DispatchCheckup"],
                       "Test" => UUIDS["Test"]),
        "sources" => Dict("DCConcurrent" => Dict("path" => "../DCConcurrent"),
                          "DispatchCheckup" => Dict("path" => CHECKUP))))))
    resolve(env)
    touch(made)
end
if (try mkdir(sandbox); true catch e; e isa Base.IOError || rethrow(); false end)
    try make_sandbox() catch; touch(failed); rethrow() end
else
    timedwait(() -> isfile(made) || isfile(failed), 600.0; pollint = 0.5) === :ok && isfile(made) ||
        error("the worker that makes DCConcurrent failed (see its first item) or took longer than 10 minutes")
end

# Run the scripts `names` side by side, their Julia processes with the depot `depot` of the sandbox first; print the
# output of any that timed out.
function fixtures(names...; depot)
    results = Dict(zip(names, asyncmap(name -> run_fixture(env, name; depot = joinpath(sandbox, "depots", depot)),
                                       collect(names); ntasks = length(names))))
    for (name, result) in results
        result.timed_out && println("$name timed out:\n", result.output)
    end
    return results
end

export fixtures, lines, show_failure
end

@testitem "the guard process runs alongside the suite; its output follows, in one block" setup = [Concurrent] begin
    results = fixtures("overlap.jl"; depot = "overlap")
    result = show_failure(results["overlap.jl"])
    @test result.code == 0
    @test lines(result.output) == ["DCT_SUITE_AFTER", "DCT_GUARD_LINE 1", "DCT_GUARD_ERR", "DCT_GUARD_LINE 2"]
end

@testitem "the status is the first nonzero one of the suite, the checks and the guards" setup = [Concurrent] begin
    results = fixtures("guard_exits.jl", "suite_exits.jl", "guard_killed.jl"; depot = "status")
    @test show_failure(results["guard_exits.jl"], 5).code == 5
    suite_exits = show_failure(results["suite_exits.jl"], 3)
    @test suite_exits.code == 3
    @test occursin("Test Failed", suite_exits.output)  # (the guards ran)
    killed = show_failure(results["guard_killed.jl"], 128 + Base.SIGKILL)
    @test killed.code == 128 + Base.SIGKILL
    @test "DCT_KILL_OUT" in lines(killed.output)
end

@testitem "a guard process that crashes keeps its output" setup = [Concurrent] begin
    results = fixtures("guard_crashed.jl"; depot = "crashed")
    result = show_failure(results["guard_crashed.jl"], 128 + 6)
    @test result.code == 128 + 6  # (SIGABRT)
    @test lines(result.output) == ["DCT_CRASH_OUT 1", "DCT_CRASH_ERR", "DCT_CRASH_OUT 2"]
    @test occursin("DCT_CRASH_INFO", result.output)
end

@testitem "a suite killed by a signal kills the guard process" setup = [Concurrent] begin
    results = fixtures("suite_killed.jl", (Sys.islinux() ? ("suite_sigkilled.jl",) : ())...; depot = "killed")
    # The guard process stopped beating (it beats for ten minutes otherwise).
    function check_stopped(result, signal)
        result.signal == signal || println(result.output)
        @test !result.timed_out && result.signal == signal
        beat = joinpath(result.markers, "beat")
        @test isfile(beat)
        before = read(beat, String)
        sleep(2)
        @test read(beat, String) == before
        @test !isfile(joinpath(result.markers, "survived"))
    end
    check_stopped(results["suite_killed.jl"], Base.SIGTERM)
    Sys.islinux() && check_stopped(results["suite_sigkilled.jl"], Base.SIGKILL)
end

@testitem "concurrent = false runs the guards after the suite" setup = [Concurrent] begin
    results = fixtures("sequential.jl"; depot = "sequential")
    result = show_failure(results["sequential.jl"])
    @test result.code == 0
    @test lines(result.output) == ["DCT_SEQUENTIAL true", "DCT_AFTER"]
end

@testitem "a guard process that cannot start fails the run" setup = [Concurrent] begin
    results = fixtures("unstartable.jl", "sequential_unstartable.jl"; depot = "unstartable")
    result = results["unstartable.jl"]
    @test result.code != 0
    @test occursin("could not start the Julia process for the original= files", result.output)
    @test !occursin("DCT_BODY_RAN", result.output)
    sequential = show_failure(results["sequential_unstartable.jl"], 1)
    @test sequential.code == 1
    @test occursin("DCT_BODY_RAN", sequential.output)
    @test occursin("DispatchCheckup: the original= process failed", sequential.output)
end

@testitem "an error at the join (here, reading the guard's output) fails the run" setup = [Concurrent] begin
    results = fixtures("join_fails.jl"; depot = "join")
    result = show_failure(results["join_fails.jl"], 1)
    @test result.code == 1
    @test occursin("DispatchCheckup: the original= process failed", result.output)
end

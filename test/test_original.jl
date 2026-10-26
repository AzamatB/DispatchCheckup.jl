# The original= process: it runs alongside the checked suite, its output follows the suite's
# in one block, its status folds into the run's, and it dies with a suite killed by a signal.
using Test
isdefined(@__MODULE__, :Fixtures) || include("support.jl")
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
    "guard_kill.jl" => "ccall(:kill, Cint, (Cint, Cint), getpid(), Base.SIGKILL)\nsleep(60)\n",
    # A suite killed by a signal kills the guard process instead of waiting for it.
    "suite_killed.jl" => activation("original = \"guard_beat.jl\"") * """
        await("beat") || exit(7)
        ccall(:kill, Cint, (Cint, Cint), getpid(), Base.SIGTERM)
        sleep(60)
        """,
    "guard_beat.jl" => PRELUDE * """
        for i in 1:600  # (two minutes)
            write(marker("beat"), string(i))
            sleep(0.2)
        end
        touch(marker("survived"))
        """,
    # concurrent = false: the guards run after the suite.
    "sequential.jl" => activation("original = \"guard_after.jl\", concurrent = false") * """
        println("DCT_SEQUENTIAL ", DispatchCheckup.ACTIVE[].guard === nothing)
        touch(marker("suite_done"))
        """,
    "guard_after.jl" => PRELUDE * "using Test\n@test isfile(marker(\"suite_done\"))\nprintln(\"DCT_AFTER\")\n",
    # A guard process that cannot start fails the run.
    "unstartable.jl" => """
        import DispatchCheckup
        @eval Base.Sys BINDIR = "/nonexistent"
        DispatchCheckup.dispatch_doctor(:DCConcurrent; original = "guard_five.jl")
        println("DCT_BODY_RAN")
        """,
)

# Run `script` in `env` with a clean load path and its own marker directory.
function run_fixture(env::String, script::String; timeout = 600)
    markers = mktempdir(env)
    variables = filter(p -> !startswith(first(p), "DISPATCH_CHECKUP") &&
                            first(p) ∉ ("JULIA_PROJECT", "JULIA_LOAD_PATH"), copy(ENV))
    merge!(variables, Dict("JULIA_LOAD_PATH" => "@:@stdlib", "DCT_MARKERS" => markers))
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

mktempdir() do sandbox
    write_files(joinpath(sandbox, "DCConcurrent"), Dict(
        "Project.toml" => Dict("name" => "DCConcurrent", "uuid" => CONCURRENT_UUID, "version" => "0.1.0"),
        "src/DCConcurrent.jl" => "module DCConcurrent\nunstable(x) = x > 0 ? x : 0.0\nend\n"))
    env = joinpath(sandbox, "env")
    write_files(env, merge(SCRIPTS, Dict("Project.toml" => Dict(
        "deps" => Dict("DCConcurrent" => CONCURRENT_UUID, "DispatchCheckup" => UUIDS["DispatchCheckup"],
                       "Test" => UUIDS["Test"]),
        "sources" => Dict("DCConcurrent" => Dict("path" => "../DCConcurrent"),
                          "DispatchCheckup" => Dict("path" => CHECKUP))))))
    resolve(env)
    names = ["overlap.jl", "guard_exits.jl", "suite_exits.jl", "guard_killed.jl", "suite_killed.jl",
             "sequential.jl", "unstartable.jl"]
    results = Dict(zip(names, asyncmap(name -> run_fixture(env, name), names; ntasks = length(names))))
    for (name, result) in results
        result.timed_out && println("$name timed out:\n", result.output)
    end
    show_failure(result, expected = 0) = (result.code == expected || println(result.output); result)

    @testset "the guard process runs alongside the suite; its output follows, in one block" begin
        result = show_failure(results["overlap.jl"])
        @test result.code == 0
        @test lines(result.output) == ["DCT_SUITE_AFTER", "DCT_GUARD_LINE 1", "DCT_GUARD_ERR", "DCT_GUARD_LINE 2"]
    end

    @testset "the status is the first nonzero one of the suite, the checks and the guards" begin
        @test show_failure(results["guard_exits.jl"], 5).code == 5
        suite_exits = show_failure(results["suite_exits.jl"], 3)
        @test suite_exits.code == 3
        @test occursin("Test Failed", suite_exits.output)  # (the guards ran)
        @test show_failure(results["guard_killed.jl"], 128 + Base.SIGKILL).code == 128 + Base.SIGKILL
    end

    @testset "a suite killed by a signal kills the guard process" begin
        result = results["suite_killed.jl"]
        result.signal == Base.SIGTERM || println(result.output)
        @test !result.timed_out && result.signal == Base.SIGTERM
        beat = joinpath(result.markers, "beat")
        @test isfile(beat)
        before = read(beat, String)
        sleep(2)
        @test read(beat, String) == before
        @test !isfile(joinpath(result.markers, "survived"))
    end

    @testset "concurrent = false runs the guards after the suite" begin
        result = show_failure(results["sequential.jl"])
        @test result.code == 0
        @test lines(result.output) == ["DCT_SEQUENTIAL true", "DCT_AFTER"]
    end

    @testset "a guard process that cannot start fails the run" begin
        result = results["unstartable.jl"]
        @test result.code != 0
        @test occursin("could not start the Julia process for the original= files", result.output)
        @test !occursin("DCT_BODY_RAN", result.output)
    end
    Fixtures.remove_overlays("DCConcurrent")
end

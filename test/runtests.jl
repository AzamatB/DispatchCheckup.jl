# DispatchCheckup's suite: the test items of test/*_tests.jl, run by ReTestItems on NWORKERS worker processes. Most
# items wait for Julia processes of their own: checked runs of generated fixture packages, Pkg.test of fixture
# packages and runs on the GPU (a missing or broken device fails the run). `Pkg.test(test_args = ["gpu_tests.jl"])`
# runs the items of the files it names. DispatchCheckup does not check its own suite with `dispatch_doctor` (its
# fixture packages are what it checks), so there is no checked run here and no original= file.
using DispatchCheckup, ReTestItems

const NWORKERS = 8   # measured at 4, 6, 8 and 10: see the report
# Under coverage, each worker writes its tracefile after every item (`<template>-items.info`): ReTestItems kills a
# worker right after its last item, often before its exit-time write. A no-op without coverage.
const WRITE_COVERAGE = :(let out = Base.JLOptions().output_code_coverage
    out == C_NULL || ccall(:jl_write_coverage_data, Cvoid, (Cstring,),
                           replace(unsafe_string(out), r"\.info$" => "-items.info"))
end)
const FILES = filter(endswith("_tests.jl"), readdir(@__DIR__))
all(in(FILES), ARGS) || error("Unknown test selection: $ARGS")
paths = isempty(ARGS) ? [@__DIR__] : [joinpath(@__DIR__, file) for file in ARGS]
# The workers get the main process's flags and package, to check (workers_tests.jl), and a scratch directory that
# outlives them, for what their items share (integration_tests.jl). The longest item takes 70-100 s; a fixture
# process that hangs is stopped after 600 s, with its output (support.jl), before the item's 900 s are up.
ReTestItems.runtests(paths...; nworkers = NWORKERS, nworker_threads = 1, retries = 0, testitem_timeout = 900,
                     test_end_expr = Expr(:block, WRITE_COVERAGE),
                     worker_init_expr = :(const MAIN_CHECK_BOUNDS = $(Base.JLOptions().check_bounds);
                                          const MAIN_DEPWARN = $(Base.JLOptions().depwarn);
                                          const MAIN_PATHOF = $(pathof(DispatchCheckup));
                                          const MAIN_SCRATCH = $(mktempdir())))

# DispatchCheckup's suite: the test items of test/*_tests.jl, run by ReTestItems on NWORKERS worker processes. Most
# items wait for Julia processes of their own: checked runs of generated fixture packages, Pkg.test of fixture
# packages and runs on the GPU (a missing or broken device fails the run). `Pkg.test(test_args = ["gpu_tests.jl"])`
# runs the items of the files it names. DispatchCheckup does not check its own suite with `dispatch_doctor` (its
# fixture packages are what it checks), so there is no checked run here and no original= file.
using DispatchCheckup, ReTestItems

const NWORKERS = 8   # measured at 4, 6, 8 and 10: see the report
const FILES = filter(endswith("_tests.jl"), readdir(@__DIR__))
all(in(FILES), ARGS) || error("Unknown test selection: $ARGS")
paths = isempty(ARGS) ? [@__DIR__] : [joinpath(@__DIR__, file) for file in ARGS]
# The workers get the main process's flags and package, to check (workers_tests.jl), and a scratch directory that
# outlives them, for what their items share (integration_tests.jl).
ReTestItems.runtests(paths...; nworkers = NWORKERS, nworker_threads = 1, retries = 0, testitem_timeout = 1800,
                     worker_init_expr = :(const MAIN_CHECK_BOUNDS = $(Base.JLOptions().check_bounds);
                                          const MAIN_DEPWARN = $(Base.JLOptions().depwarn);
                                          const MAIN_PATHOF = $(pathof(DispatchCheckup));
                                          const MAIN_SCRATCH = $(mktempdir())))

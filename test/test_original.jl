using Test, TOML
isdefined(@__MODULE__, :DispatchCheckupFixtures) || include("fixtures/support.jl")

@testset "original-source test subprocesses" begin
    DispatchCheckupFixtures.with_sandbox() do sandbox
        fixtures = DispatchCheckupFixtures
        @testset "inert import and commented activation" begin
            code = """
                using Test
                import DispatchCheckup
                @test !isdefined(DispatchCheckup, :Implementation)
                @test !DispatchCheckup.test_original()
                @test !isdefined(DispatchCheckup, :Implementation)
                @test !any(id -> id.name == "DispatchDoctor", keys(Base.loaded_modules))
                """
            command = Cmd(vcat(Base.julia_cmd().exec,
                ["--startup-file=no", "--project=$(sandbox.environment)", "-e", code]))
            result = fixtures.capture(sandbox, "original-inert", command)
            @test result.code == 0
            ordinary = fixtures.run_script(sandbox, "original-commented", raw"""
                using Test, DCFixtureTarget
                @test !DispatchCheckup.test_original(test_args=["unused"])
                @test DCFixtureTarget.root_unstable(1) === 1
                @test DispatchCheckup.source_root(DCFixtureTarget) == pkgdir(DCFixtureTarget)
                """; active=false)
            @test ordinary.code == 0
            @test ordinary.originals_unchanged
            @test count(==("DCT_BODY_COMPLETE"), split(ordinary.output, '\n')) == 1
        end

        @testset "selectors, original identity, no recursion, and checked continuation" begin
            report_path = joinpath(sandbox.root, "ordinary-report.toml")
            body = raw"""
                using Test
                if !isempty(ARGS) && first(ARGS) == "ordinary"
                    using DCFixtureTarget
                    @test ARGS == ["ordinary", "alpha beta", "λ"]
                    @test ENV["DCT_ORIGINAL_SENTINEL"] == "ordinary value λ"
                    @test realpath(pkgdir(DCFixtureTarget)) == realpath(ENV["DCT_ORIGINAL_TARGET"])
                    @test DispatchCheckup.source_root(DCFixtureTarget) == pkgdir(DCFixtureTarget)
                    @test DCFixtureTarget.root_unstable(1) === 1
                    @test !DispatchCheckup.test_original(test_args=["must-not-recurse"])
                    impl = DispatchCheckup._implementation()
                    config = impl.TOML.parsefile(ENV["DISPATCH_CHECKUP_CHILD_CONFIG"])
                    @test Base.active_project() == config["original_project_file"]
                    @test LOAD_PATH == config["original_load_path"]
                    @test DEPOT_PATH == config["original_depot_path"]
                    @test abspath(PROGRAM_FILE) == @__FILE__
                    fixture = joinpath(pkgdir(DCFixtureTarget), "test", "generated-original-fixture.jl")
                    mkpath(dirname(fixture))
                    try
                        write(fixture, "original_fixture_value = 7\n")
                        include(fixture)
                        @test original_fixture_value == 7
                    finally
                        rm(fixture; force=true)
                    end
                    probe = "import DispatchCheckup; DispatchCheckup.dispatch_doctor(:DCFixtureTarget)"
                    mktemp() do _, io
                        command = Cmd(vcat(Base.julia_cmd().exec,
                            ["--startup-file=no", "--project=$(dirname(Base.active_project()))", "-e", probe, "--"], ARGS))
                        process = run(pipeline(ignorestatus(command); stdout=io, stderr=io))
                        seekstart(io)
                        @test process.exitcode != 0
                        @test occursin("inherited without its isolated test controller", read(io, String))
                    end
                    probe = string("import DispatchCheckup; DispatchCheckup._original_main(ENV[",
                                   repr("DISPATCH_CHECKUP_CHILD_CONFIG"), "])")
                    mktemp() do _, io
                        command = Cmd(vcat(Base.julia_cmd().exec,
                            ["--startup-file=no", "--project=$(dirname(Base.active_project()))", "-e", probe, "--"], ARGS))
                        process = run(pipeline(ignorestatus(command); stdout=io, stderr=io))
                        seekstart(io)
                        @test process.exitcode != 0
                        @test occursin("private controller", read(io, String))
                    end
                    println("DCT_ORIGINAL_COMPLETE")
                else
                    @test !fixture_loaded("DCFixtureTarget")
                    @test DispatchCheckup.test_original(test_args=["ordinary", "alpha beta", "λ"],
                        env=["DCT_ORIGINAL_SENTINEL" => "ordinary value λ"])
                    @test fixture_loaded("DCFixtureTarget")
                    @test !haskey(ENV, "DCT_ORIGINAL_SENTINEL")
                    using DCFixtureTarget
                    failure = try DCFixtureTarget.root_unstable(1) catch exception; exception end
                    @test nameof(typeof(failure)) === :TypeInstabilityError
                end
                """
            result = fixtures.run_script(sandbox, "original-selected", body; report=report_path)
            result.code == 0 || @error "original-source fixture failed" output=result.output
            @test result.code == 0
            @test result.originals_unchanged
            @test count(==("DCT_ORIGINAL_COMPLETE"), split(result.output, '\n')) == 1
            @test count(==("DCT_BODY_COMPLETE"), split(result.output, '\n')) == 2
            report = TOML.parsefile(report_path)
            run = only(report["original_tests"])
            @test run["exit_code"] == 0 && run["validation_status"] == "passed"
            @test run["test_args"] == ["ordinary", "alpha beta", "λ"]
            @test run["env"] == Dict("DCT_ORIGINAL_SENTINEL" => "ordinary value λ")
            @test run["project_file"] == joinpath(sandbox.environment, "Project.toml")
            @test run["target_entry"] == joinpath(sandbox.target, "src", "DCFixtureTarget.jl")
        end

        @testset "Pkg.test preserves setup and empty PROGRAM_FILE" begin
            result = fixtures.run_pkg_test(sandbox, "original-pkg-test", raw"""
                using Test, DCFixtureTarget
                const fixture_setup_value = 17
                if ARGS == ["ordinary"]
                    @test isempty(PROGRAM_FILE)
                    @test fixture_setup_value == 17
                    @test DCFixtureTarget.root_unstable(1) === 1
                    @test !DispatchCheckup.test_original()
                else
                    @test DispatchCheckup.test_original(test_args=["ordinary"])
                end
                """)
            result.code == 0 || @error "original Pkg.test fixture failed" output=result.output
            @test result.code == 0
            @test result.originals_unchanged
            @test count(==("DCT_BODY_COMPLETE"), split(result.output, '\n')) == 2
        end

        @testset "failure propagates and invariant overrides are rejected" begin
            report_path = joinpath(sandbox.root, "ordinary-failure-report.toml")
            result = fixtures.run_script(sandbox, "original-exit", raw"""
                using Test, DCFixtureTarget
                if ARGS == ["ordinary-failure"]
                    exit(37)
                end
                DispatchCheckup.test_original(test_args=["ordinary-failure"])
                println("DCT_UNEXPECTED_CONTINUATION")
                """; report=report_path)
            @test result.code == 37
            @test !occursin("DCT_UNEXPECTED_CONTINUATION", result.output)
            @test result.originals_unchanged
            @test only(TOML.parsefile(report_path)["original_tests"])["exit_code"] == 37
            invalid = fixtures.run_script(sandbox, "original-env-rejected", raw"""
                using Test, DCFixtureTarget
                for name in ("JULIA_PROJECT", "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH",
                             "DISPATCH_CHECKUP_CHILD_TOKEN", "DISPATCH_CHECKUP_REPORT")
                    @test_throws ArgumentError DispatchCheckup.test_original(env=[name => "changed"])
                end
                @test_throws ArgumentError DispatchCheckup.test_original(test_args=[:guards])
                @test_throws ArgumentError DispatchCheckup.test_original(env=["flag" => 1])
                """)
            @test invalid.code == 0
            @test invalid.originals_unchanged
        end

        @testset "original source changes cannot produce a successful report" begin
            entry = joinpath(sandbox.target, "src", "DCFixtureTarget.jl")
            saved = read(entry)
            report_path = joinpath(sandbox.root, "ordinary-source-mismatch.toml")
            try
                result = fixtures.run_script(sandbox, "original-source-mismatch", raw"""
                    using Test, DCFixtureTarget
                    if ARGS == ["ordinary-mutation"]
                        open(pathof(DCFixtureTarget), "a") do io
                            println(io, "# changed by original-source validation fixture")
                        end
                        exit(0)
                    end
                    DispatchCheckup.test_original(test_args=["ordinary-mutation"])
                    """; report=report_path)
                @test result.code != 0
                run = only(TOML.parsefile(report_path)["original_tests"])
                @test run["exit_code"] != 0
                @test run["validation_status"] == "failed"
                @test occursin("original package source changed", run["validation_error"])
            finally
                write(entry, saved)
            end
        end
    end
end

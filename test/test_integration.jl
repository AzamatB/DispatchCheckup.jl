using Test, TOML
isdefined(@__MODULE__, :DispatchCheckupFixtures) || include("fixtures/support.jl")
const DCF = DispatchCheckupFixtures

const FIXTURE_IMPORTS = raw"""
using Test, DCFixtureTarget, DCFixtureDependency, DCFixtureConsumer, Dates
const Target = DCFixtureTarget
const extension = Base.get_extension(Target, :DCFixtureTargetDatesExt)
@test extension !== nothing
@test string(Base.PkgId(Target).uuid) == "eadb23ac-f16a-4969-a7d5-a895e9f8275b"
@test Target.Token === DCFixtureDependency.Token
@test DCFixtureConsumer.DCFixtureTarget === Target
@test DCFixtureConsumer.token_type() === Target.Token
@test DCFixtureConsumer.make_token(7) isa DCFixtureDependency.Token
@test Target.token(7).value == 7
@test Target.stable(1) === 2
@test Target.Nested.stable(1) === 3
@test Target.BareNested.stable(1) === 4
@test Target.extension_value(Date(2025, 1, 2)) == 2025
@test Target.mapped_file_loaded
@test length(Target.map_hits) >= 3
@test DCFixtureDependency.dependency_unstable(1) === 1
println("DCT_TARGET_PATH=", pkgdir(Target))
function expect_unstable(f, args...)
    result = try
        f(args...)
    catch exception
        exception
    end
    @test nameof(typeof(result)) === :TypeInstabilityError
end
"""

const ALL_UNSTABLE_METHODS = raw"""
(Target.root_unstable, Target.static_unstable, Target.bare_unstable, Target.mapped_unstable,
 Target.qualified_unstable, Target.base_mapped_unstable,
 Target.dynamic_unstable, Target.string_unstable, Target.mapped_string_unstable,
 Target.Nested.foo, Target.Nested.nested_unstable, Target.Nested.nested_include_unstable,
 Target.BareNested.baremodule_unstable,
 extension.ext_unstable, extension.Nested.nested_ext_unstable)
"""

function check_success(result)
    result.code == 0 || @error "fixture failed" log=result.log output=result.output
    @test result.code == 0
    @test result.originals_unchanged
    @test count(==("DCT_BODY_COMPLETE"), split(result.output, '\n')) == 1
end

function check_cleaned_overlay(result, sandbox)
    projects = DCF.printed_paths(result, "DCT_ACTIVE_PROJECT")
    @test length(projects) == 1
    for project in projects
        @test project != joinpath(sandbox.environment, "Project.toml")
        @test project != joinpath(sandbox.target, "Project.toml")
        @test !ispath(dirname(project))
    end
    for target in DCF.printed_paths(result, "DCT_TARGET_PATH")
        @test target != sandbox.target
        @test !ispath(target)
    end
end

@testset "DispatchCheckup package-loader integration" begin
    DCF.with_sandbox() do sandbox
        ordinary_body = FIXTURE_IMPORTS * """
            @test !fixture_loaded("DispatchDoctor")
            @test Base.active_project() == fixture_original_project
            @test LOAD_PATH == fixture_original_load_path
            @test DEPOT_PATH == fixture_original_depot_path
            @test Dict(ENV) == fixture_original_environment
            for f in $ALL_UNSTABLE_METHODS
                @test f(1) === 1
            end
            @test Target.foo(1) === 1 && Target.bar(1) === 1
            @test Target.foo(Int32(1)) === Int32(1)
            @test isempty(PROGRAM_FILE)
            """

        @testset "commented activation is ordinary Pkg.test" begin
            # First run creates the ordinary target cache; the second must reuse
            # that cache without any instrumentation or preference writes.
            first = DCF.run_pkg_test(sandbox, "ordinary-warm", ordinary_body; active=false)
            check_success(first)
            @test occursin("DCT_EMPTY_PROGRAM_FILE_ENTRY", first.output)
            before_cache = DCF.target_cache_fingerprints()
            @test !isempty(before_cache)
            second = DCF.run_pkg_test(sandbox, "ordinary-repeat", ordinary_body; active=false)
            check_success(second)
            @test before_cache == DCF.target_cache_fingerprints()
        end

        @testset "actual Pkg.test instruments every supported source path" begin
            body = FIXTURE_IMPORTS * """
                @test fixture_loaded("DispatchDoctor")
                @test isempty(PROGRAM_FILE)
                @test ARGS == ["alpha beta", "λ", "--sentinel"]
                @test ENV["DCT_SENTINEL"] == "spaces and unicode λ preserved"
                @test pwd() == ENV["DCT_EXPECTED_CWD"]
                @test Target.foo(1) === 1 && Target.bar(1) === 1
                @test Target.foo(Int32(1)) === Int32(1)
                for f in $ALL_UNSTABLE_METHODS
                    expect_unstable(f, 1)
                end
                DispatchCheckup.dispatch_doctor(:DCFixtureTarget; unstable=(:foo, :bar))
                """
            before_cache = DCF.target_cache_fingerprints()
            result = DCF.run_pkg_test(sandbox, "active-pkg-test", body;
                unstable=(:foo, :bar), repeat=true, args=["alpha beta", "λ", "--sentinel"])
            check_success(result)
            @test occursin("DCT_EMPTY_PROGRAM_FILE_ENTRY", result.output)
            flags = DCF.printed_paths(result, "DCT_ENTRY_FLAGS")
            @test length(flags) == 2
            @test allequal(flags)
            check_cleaned_overlay(result, sandbox)
            @test before_cache == DCF.target_cache_fingerprints()
        end

        @testset "qualified exclusions do not disable adjacent methods" begin
            body = FIXTURE_IMPORTS * raw"""
                @test Target.Nested.foo(1) === 1
                @test extension.ext_unstable(1) === 1
                expect_unstable(Target.foo, 1)
                expect_unstable(Target.foo, Int32(1))
                expect_unstable(Target.bar, 1)
                expect_unstable(Target.Nested.nested_unstable, 1)
                expect_unstable(extension.Nested.nested_ext_unstable, 1)
                if abspath(PROGRAM_FILE) == @__FILE__
                    println("DCT_GUARDED_DIRECT_ENTRY")
                end
                """
            entrypoint = joinpath(sandbox.root, "qualified-exclusions.jl")
            report_path = joinpath(sandbox.root, "reports", "qualified.toml")
            result = DCF.run_script(sandbox, "qualified-exclusions", body;
                unstable=(Symbol("DCFixtureTarget.Nested.foo"),
                          Symbol("DCFixtureTargetDatesExt.ext_unstable")),
                require_all=true, entrypoint, report=report_path)
            check_success(result)
            @test occursin("DCT_GUARDED_DIRECT_ENTRY", result.output)
            check_cleaned_overlay(result, sandbox)
            @test isfile(report_path)
            report = TOML.parsefile(report_path)
            @test report["target_name"] == "DCFixtureTarget"
            @test report["target_uuid"] == DCF.FIXTURE_UUIDS["DCFixtureTarget"]
            @test report["counts"]["instrumented"] >= 15
            @test report["counts"]["excluded"] == 2
            @test report["counts"]["unsupported"] == 0
            @test report["exclusions"]["DCFixtureTarget.Nested.foo"] == 1
            @test report["exclusions"]["DCFixtureTargetDatesExt.ext_unstable"] == 1
            @test realpath(report["target_provenance"]["path"]) == realpath(sandbox.target)
            @test report["helper_provenance"]["uuid"] == "ca055ede-32eb-4961-937e-82d9c5ec6430"
            @test report["doctor_provenance"]["uuid"] == "8d63f2c5-f18a-4cf2-ba9d-b3f60fc568c8"
            @test report["dispatch_doctor_version"] == report["doctor_provenance"]["version"]
            @test all(path -> startswith(path, sandbox.target * string(Base.Filesystem.path_separator)), report["files"])
            @test joinpath(sandbox.target, "ext", "DCFixtureTargetDatesExt.jl") in report["entries"]
        end

        @testset "instrumented dependencies remain precompilable" begin
            before_cache = DCF.target_cache_fingerprints()
            result = DCF.run_script(sandbox, "active-precompile", FIXTURE_IMPORTS * raw"""
                using Pkg
                expect_unstable(Target.root_unstable, 1)
                Pkg.precompile(["DCFixtureConsumer"]; strict=true)
                expect_unstable(Target.root_unstable, 1)
                @test DCFixtureConsumer.token_type() === Target.Token
                probe = "using DCFixtureConsumer; import DCFixtureTarget; failure = try DCFixtureTarget.root_unstable(1) catch exception; exception end; @assert nameof(typeof(failure)) === :TypeInstabilityError; print(:DCT_CACHED_GUARD_OK)"
                cached = read(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $probe`, String)
                @test cached == "DCT_CACHED_GUARD_OK"
                println("DCT_PRECOMPILE_OK")
                """; unstable=(:foo, :bar))
            check_success(result)
            @test occursin("DCT_PRECOMPILE_OK", result.output)
            check_cleaned_overlay(result, sandbox)
            @test before_cache == DCF.target_cache_fingerprints()
        end

        @testset "unmatched exclusions and activation mismatch fail" begin
            unmatched = DCF.run_script(sandbox, "unmatched", "using DCFixtureTarget\n";
                                       unstable=(:misspelled_function,))
            @test unmatched.code != 0
            @test unmatched.originals_unchanged
            @test occursin("unmatched unstable exclusions", lowercase(unmatched.output))

            mismatch = DCF.run_script(sandbox, "mismatch", raw"""
                DispatchCheckup.dispatch_doctor(:DCFixtureTarget; unstable=(:bar,))
                using DCFixtureTarget
                """; unstable=(:foo,))
            @test mismatch.code != 0
            @test mismatch.originals_unchanged
            @test occursin(r"(?i)(configuration|exclusions|mismatch)", mismatch.output)
            @test !occursin("DCT_BODY_COMPLETE", mismatch.output)

            failure_report = joinpath(sandbox.root, "reports", "exit-zero-unmatched.toml")
            exited = DCF.run_script(sandbox, "exit-zero-unmatched", "using DCFixtureTarget\nexit(0)\n";
                unstable=(:misspelled_function,), report=failure_report)
            @test exited.code != 0
            @test exited.originals_unchanged
            @test occursin("unmatched unstable exclusions", lowercase(exited.output))
            @test isfile(failure_report)
            report = TOML.parsefile(failure_report)
            @test report["exclusions"]["DCFixtureTarget.misspelled_function"] == 0
            @test report["target_uuid"] == DCF.FIXTURE_UUIDS["DCFixtureTarget"]
        end

        @testset "child configuration cannot be spoofed or reused with a different token" begin
            spoofed = DCF.run_script(sandbox, "spoofed-config", "using DCFixtureTarget\n";
                extra_env=Dict("DISPATCH_CHECKUP_CHILD_CONFIG" => joinpath(sandbox.root, "missing-config.toml"),
                               "DISPATCH_CHECKUP_CHILD_TOKEN" => "not-a-launcher-token",
                               "DISPATCH_CHECKUP_CHILD_DIGEST" => "not-a-config-digest"))
            @test spoofed.code != 0
            @test spoofed.originals_unchanged
            @test occursin(r"(?i)(configuration|marker|token)", spoofed.output)
            @test !occursin("DCT_BODY_COMPLETE", spoofed.output)

            tampered = DCF.run_script(sandbox, "tampered-token", raw"""
                using DCFixtureTarget
                ENV["DISPATCH_CHECKUP_CHILD_TOKEN"] = "modified-after-activation"
                DispatchCheckup.dispatch_doctor(:DCFixtureTarget)
                """)
            @test tampered.code != 0
            @test tampered.originals_unchanged
            @test occursin("token", lowercase(tampered.output))
            @test !occursin("DCT_BODY_COMPLETE", tampered.output)

            inherited = DCF.run_script(sandbox, "inherited-controller", raw"""
                using Test, DCFixtureTarget
                probe = "import DispatchCheckup; DispatchCheckup.dispatch_doctor(:DCFixtureTarget)"
                mktemp() do _, io
                    command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $probe`
                    process = run(pipeline(ignorestatus(command); stdout=io, stderr=io))
                    seekstart(io)
                    output = read(io, String)
                    @test process.exitcode != 0
                    @test occursin("inherited without its isolated test controller", output)
                end
                """)
            check_success(inherited)
            check_cleaned_overlay(inherited, sandbox)
        end

        @testset "exit status and inherited process state" begin
            result = DCF.run_script(sandbox, "exit-status", FIXTURE_IMPORTS * raw"""
                @test ARGS == ["one argument", "--literal"]
                @test ENV["DCT_SENTINEL"] == "spaces and unicode λ preserved"
                @test pwd() == ENV["DCT_EXPECTED_CWD"]
                println("DCT_EXPECTED_EXIT")
                exit(37)
                """; unstable=(:foo, :bar), args=["one argument", "--literal"])
            @test result.code == 37
            @test result.originals_unchanged
            @test occursin("DCT_EXPECTED_EXIT", result.output)
            check_cleaned_overlay(result, sandbox)
        end

        @testset "tests may consume arguments and change working project" begin
            result = DCF.run_script(sandbox, "mutable-test-state", FIXTURE_IMPORTS * raw"""
                using Pkg
                @test popfirst!(ARGS) == "consumed"
                @test isempty(ARGS)
                destination = joinpath(ENV["DCT_EXPECTED_CWD"], "changed-working-directory")
                mkpath(destination)
                cd(destination)
                Pkg.activate(ENV["DCT_ORIGINAL_TARGET"]; io=devnull)
                expect_unstable(Target.root_unstable, 1)
                @test pwd() == destination
                """; unstable=(:foo, :bar), args=["consumed"])
            check_success(result)
            check_cleaned_overlay(result, sandbox)
        end

        @testset "concurrent activations retain independent exclusions" begin
            before = DCF.original_fingerprints(sandbox)
            left = @async DCF.run_script(sandbox, "concurrent-foo", FIXTURE_IMPORTS * raw"""
                @test Target.foo(1) === 1
                expect_unstable(Target.bar, 1)
                sleep(0.2)
                """; unstable=(:foo,))
            right = @async DCF.run_script(sandbox, "concurrent-bar", FIXTURE_IMPORTS * raw"""
                @test Target.bar(1) === 1
                expect_unstable(Target.foo, 1)
                sleep(0.2)
                """; unstable=(:bar,))
            results = (fetch(left), fetch(right))
            for result in results
                check_success(result)
                check_cleaned_overlay(result, sandbox)
            end
            @test only(DCF.printed_paths(results[1], "DCT_ACTIVE_PROJECT")) !=
                  only(DCF.printed_paths(results[2], "DCT_ACTIVE_PROJECT"))
            @test before == DCF.original_fingerprints(sandbox)
        end

        @testset "reported DispatchDoctor skips and strict coverage" begin
            body = raw"""
                using Test, DCFixtureSkipped
                @test DCFixtureSkipped.stable(1) === 2
                @test DCFixtureSkipped.callback(1) === 1
                """
            reported = DCF.run_script(sandbox, "reported-skip", body; target=:DCFixtureSkipped)
            check_success(reported)
            @test occursin(r"(?i)(skip|unsupported|uninstrument)", reported.output)
            @test occursin(r"(?i)(closure|anonymous|->)", reported.output)
            strict = DCF.run_script(sandbox, "strict-skip", body;
                                    target=:DCFixtureSkipped, require_all=true)
            @test strict.code != 0
            @test strict.originals_unchanged
            @test occursin(r"(?i)(closure|anonymous|->)", strict.output)
        end

        @testset "dynamic outside-root include cannot escape instrumentation" begin
            entry = joinpath(sandbox.target, "src", "DCFixtureTarget.jl")
            original = read(entry, String)
            outside = joinpath(sandbox.root, "outside.jl")
            write(outside, "outside_unstable(x::Int) = x > 0 ? x : Float64(x)\n")
            try
                write(entry, replace(original, r"\nend\s*$" =>
                    "\ninclude(ENV[\"DCT_OUTSIDE_INCLUDE\"])\nend\n"))
                result = DCF.run_script(sandbox, "outside-include", "using DCFixtureTarget\n";
                    extra_env=Dict("DCT_OUTSIDE_INCLUDE" => outside))
                @test result.code != 0
                @test result.originals_unchanged
                @test occursin(r"(?i)(outside|escape)", result.output)
                @test !occursin("DCT_BODY_COMPLETE", result.output)
            finally
                write(entry, original)
            end
        end

        @testset "aliased includes cannot silently replace checked methods" begin
            entry = joinpath(sandbox.target, "src", "DCFixtureTarget.jl")
            original = read(entry, String)
            alias_source = joinpath(sandbox.target, "src", "alias.jl")
            write(alias_source, "alias_unstable(x::Int) = x > 0 ? x : Float64(x)\n")
            variants = (
                ("alias-new-file", "const raw_include = include\nraw_include(\"alias.jl\")"),
                # bare.jl has already been mapped above. Checking a set of seen
                # paths would miss this second, uninstrumented definition.
                ("alias-repeated-file", "const raw_include = Base.include\nraw_include(@__MODULE__, joinpath(@__DIR__, \"bare.jl\"))"),
            )
            try
                for (label, insertion) in variants
                    write(entry, replace(original, r"\nend\s*$" => "\n" * insertion * "\nend\n"))
                    result = DCF.run_script(sandbox, label, "using DCFixtureTarget\n")
                    @test result.code != 0
                    @test result.originals_unchanged
                    @test occursin("included source bypassed instrumentation", lowercase(result.output))
                end
            finally
                write(entry, original)
                rm(alias_source; force=true)
            end
        end

        @testset "include_string aliases cannot bypass source coverage" begin
            entry = joinpath(sandbox.target, "src", "DCFixtureTarget.jl")
            original = read(entry, String)
            try
                for (label, reference) in (("string-alias", "Base.include_string"),
                                           ("string-getfield-alias", "getfield(Base, :include_string)"))
                    insertion = "const raw_string_loader = " * reference * "\n" *
                        "raw_string_loader(@__MODULE__, \"string_alias_unstable(x::Int) = x > 0 ? x : Float64(x)\", \"aliased-string\")"
                    write(entry, replace(original, r"\nend\s*$" => "\n" * insertion * "\nend\n"))
                    result = DCF.run_script(sandbox, label, "using DCFixtureTarget\n")
                    @test result.code != 0
                    @test result.originals_unchanged
                    @test occursin("first-class include_string reference", result.output)
                end
            finally
                write(entry, original)
            end
        end

        @testset "already-loaded target is rejected" begin
            script = joinpath(sandbox.root, "already-loaded.jl")
            write(script, "using DCFixtureTarget\nimport DispatchCheckup\n" *
                "DispatchCheckup.dispatch_doctor(:DCFixtureTarget)\n")
            before = DCF.original_fingerprints(sandbox)
            result = DCF.capture(sandbox, "already-loaded",
                `$(Base.julia_cmd()) --startup-file=no --depwarn=error --project=$(sandbox.environment) $script`)
            @test result.code != 0
            @test occursin(r"(?i)(already.loaded|before.*load)", result.output)
            @test before == DCF.original_fingerprints(sandbox)
        end
    end
end

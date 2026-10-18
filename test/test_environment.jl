module TestEnvironment

using Test, TOML, UUIDs
import DispatchCheckup

const I = DispatchCheckup._implementation()
_call(name, args...) = Base.invokelatest(Base.invokelatest(getglobal, I, name), args...)

function write_toml(path, data)
    open(path, "w") do io
        TOML.print(io, data)
    end
end

@testset "environment snapshots preserve locked records and select the versioned manifest" begin
    mktempdir() do root
        project_file = joinpath(root, "Project.toml")
        uuid = string(uuid4())
        write_toml(project_file, Dict("deps" => Dict("Locked" => uuid)))
        function manifest(version)
            Dict("manifest_format" => "2.0", "julia_version" => string(VERSION),
                 "deps" => Dict("Locked" => [Dict("uuid" => uuid, "version" => version,
                     "path" => "../locked", "repo-url" => "../git-source",
                     "repo-rev" => "immutable-fixture", "git-tree-sha1" => "1"^40)]))
        end
        ordinary = joinpath(root, "Manifest.toml")
        versioned = joinpath(root, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
        write_toml(ordinary, manifest("1.2.3"))
        write_toml(versioned, manifest("1.2.4"))
        originals = Dict(file => read(file) for file in (project_file, ordinary, versioned))
        active, load_path = Base.active_project(), copy(LOAD_PATH)
        snapshot = _call(:_read_environment, project_file)
        record = only(snapshot.manifest["deps"]["Locked"])
        @test snapshot.manifest_file == versioned
        @test record["version"] == "1.2.4"
        @test record["repo-rev"] == "immutable-fixture"
        @test record["git-tree-sha1"] == "1"^40
        @test record["path"] == abspath(root, "../locked")
        @test record["repo-url"] == abspath(root, "../git-source")
        @test Base.active_project() == active
        @test LOAD_PATH == load_path
        @test all(read(file) == data for (file, data) in originals)
    end
end

@testset "source snapshots are writable copies and large assets are shared" begin
    mktempdir() do root
        original, snapshot = joinpath(root, "original"), joinpath(root, "snapshot")
        mkpath(joinpath(original, "src"))
        source = joinpath(original, "src", "Code.jl")
        write(source, "f() = 1\n")
        chmod(source, 0o444)
        symlink("Code.jl", joinpath(original, "src", "Alias.jl"))
        shared_source = mkpath(joinpath(root, "shared-source"))
        write(joinpath(shared_source, "Shared.jl"), "shared() = 1\n")
        symlink(shared_source, joinpath(original, "shared"); dir_target=true)
        symlink(original, joinpath(original, "again"); dir_target=true)
        write(joinpath(original, "Project.toml"), "name = \"Code\"\n")
        asset = joinpath(original, "large.dat")
        open(asset, "w") do io
            truncate(io, 64 * 1024 * 1024)
        end
        _call(:_copy_package_tree, original, snapshot)
        copied = joinpath(snapshot, "src", "Code.jl")
        @test !islink(copied)
        @test !islink(joinpath(snapshot, "src", "Alias.jl"))
        @test islink(joinpath(snapshot, "large.dat"))
        @test realpath(joinpath(snapshot, "large.dat")) == asset
        @test lstat(joinpath(snapshot, "large.dat")).size < 1024
        @test stat(copied).mode & 0o200 != 0
        @test !islink(joinpath(snapshot, "shared"))
        @test read(joinpath(snapshot, "shared", "Shared.jl"), String) == "shared() = 1\n"
        @test realpath(joinpath(snapshot, "again")) == snapshot
        fingerprint = _call(:_source_fingerprint, snapshot)
        write(copied, "f() = 2\n")
        @test read(source, String) == "f() = 1\n"
        @test _call(:_source_fingerprint, snapshot) != fingerprint
    end
end

@testset "package-root aliases keep source entries inside the canonical root" begin
    mktempdir() do root
        uuid = uuid4()
        package = mkpath(joinpath(root, "Package"))
        source = mkpath(joinpath(root, "shared-source"))
        write(joinpath(source, "RootAliasFixture.jl"), "module RootAliasFixture end\n")
        symlink(source, joinpath(package, "src"); dir_target=true)
        write_toml(joinpath(package, "Project.toml"), Dict(
            "name" => "RootAliasFixture", "uuid" => string(uuid)))
        alias = joinpath(root, "PackageAlias")
        symlink(package, alias; dir_target=true)
        environment = mkpath(joinpath(root, "environment"))
        project_file = joinpath(environment, "Project.toml")
        write_toml(project_file, Dict("deps" => Dict("RootAliasFixture" => string(uuid))))
        write_toml(joinpath(environment, "Manifest.toml"), Dict(
            "manifest_format" => "2.0", "julia_version" => string(VERSION),
            "deps" => Dict("RootAliasFixture" => [Dict("uuid" => string(uuid), "path" => alias)])))
        id = Base.PkgId(uuid, "RootAliasFixture")
        pushfirst!(LOAD_PATH, project_file)
        try
            location = _call(:_locate_package, id)
            @test location.root == realpath(package)
            @test location.entry == joinpath(realpath(package), "src", "RootAliasFixture.jl")
            @test realpath(location.entry) == joinpath(source, "RootAliasFixture.jl")
            @test !haskey(Base.loaded_modules, id)
        finally
            popfirst!(LOAD_PATH)
        end
    end
end

@testset "manifest-free packages retain optional extension dependencies" begin
    mktempdir() do root
        uuid, weak_uuid, hard_uuid = uuid4(), uuid4(), uuid4()
        write_toml(joinpath(root, "Project.toml"), Dict(
            "name" => "OptionalFixture", "uuid" => string(uuid), "version" => "0.1.0",
            "deps" => Dict("Hard" => string(hard_uuid), "Weak" => string(weak_uuid)),
            "weakdeps" => Dict("Weak" => string(weak_uuid)),
            "extensions" => Dict("OptionalFixtureWeakExt" => "Weak")))
        location = _call(:PackageLocation, Base.PkgId(uuid, "OptionalFixture"), root,
                         joinpath(root, "src", "OptionalFixture.jl"), root)
        record = _call(:_project_record, location)
        @test record["deps"] == Dict("Hard" => string(hard_uuid))
        @test record["weakdeps"] == Dict("Weak" => string(weak_uuid))
        @test record["extensions"] == Dict("OptionalFixtureWeakExt" => "Weak")
    end
end

@testset "strict target preferences leave originals and unrelated preferences intact" begin
    mktempdir() do root
        uuid, other_uuid = uuid4(), uuid4()
        original_project = Dict("deps" => Dict("PreferenceTarget" => string(uuid),
                                                "PreferenceOther" => string(other_uuid)))
        project_file = joinpath(root, "Project.toml")
        preference_file = joinpath(root, "LocalPreferences.toml")
        write_toml(project_file, original_project)
        write_toml(preference_file, Dict(
            "PreferenceTarget" => Dict("dispatch_doctor_mode" => "disable",
                "dispatch_doctor_union_limit" => 9, "dispatch_doctor_codegen_level" => "min",
                "backend" => "fixture"),
            "PreferenceOther" => Dict("threads" => 7)))
        original_bytes = read(preference_file)
        project = Dict{String,Any}("deps" => deepcopy(original_project["deps"]))
        manifest = Dict{String,Any}("deps" => Dict(
            "PreferenceTarget" => [Dict("uuid" => string(uuid))],
            "PreferenceOther" => [Dict("uuid" => string(other_uuid))]))
        pushfirst!(LOAD_PATH, project_file)
        try
            preferences = _call(:_temporary_preferences!, project, manifest, Base.PkgId(uuid, "PreferenceTarget"))
            @test preferences["PreferenceTarget"]["dispatch_doctor_mode"] == "error"
            @test preferences["PreferenceTarget"]["dispatch_doctor_union_limit"] == 1
            @test preferences["PreferenceTarget"]["dispatch_doctor_codegen_level"] == "debug"
            @test preferences["PreferenceTarget"]["backend"] == "fixture"
            @test preferences["PreferenceOther"]["threads"] == 7
            @test read(preference_file) == original_bytes
        finally
            popfirst!(LOAD_PATH)
        end
    end
end

end

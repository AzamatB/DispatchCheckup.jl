const CHECKUP_UUID = UUIDs.UUID("ca055ede-32eb-4961-937e-82d9c5ec6430")
const DOCTOR_UUID = UUIDs.UUID("8d63f2c5-f18a-4cf2-ba9d-b3f60fc568c8")

struct PackageLocation
    id::Base.PkgId
    root::String
    entry::String
    environment::String
end

struct EnvironmentSnapshot
    project_file::String
    manifest_file::String
    project::Dict{String,Any}
    manifest::Dict{String,Any}
end

struct OverlayEnvironment
    root::String
    project_file::String
    config_file::String
    bootstrap_file::String
    depot::String
    target::PackageLocation
    overlay_root::String
    snapshot_root::String
    token::String
    digest::String
end

function _project_file(root::String)
    for name in ("JuliaProject.toml", "Project.toml")
        file = joinpath(root, name)
        isfile(file) && return file
    end
    throw(ArgumentError("no package Project.toml in $root"))
end

function _locate_package(id::Base.PkgId)
    found = lock(Base.require_lock) do
        Base.locate_package_env(id)
    end
    found === nothing && throw(ArgumentError("cannot locate package $(id.name) in the current environment"))
    entry, environment = found
    entry = abspath(entry)
    root = dirname(entry)
    while true
        for name in ("JuliaProject.toml", "Project.toml")
            project = joinpath(root, name)
            if isfile(project)
                data = TOML.parsefile(project)
                if get(data, "uuid", "") == string(id.uuid)
                    # Canonicalize a symlinked package root together with its
                    # entry, retaining source-directory aliases within it.
                    canonical_root = realpath(root)
                    canonical_entry = joinpath(canonical_root, relpath(entry, root))
                    return PackageLocation(id, canonical_root, canonical_entry, String(environment))
                end
            end
        end
        parent = dirname(root)
        parent == root && break
        root = parent
    end
    throw(ArgumentError("cannot find the project owning $(id.name) at $entry"))
end

function _locate_target(name::Symbol)
    id = Base.identify_package(String(name))
    id === nothing && throw(ArgumentError("package $name is not available in the current environment"))
    id.uuid === nothing && throw(ArgumentError("$name must be a package with a UUID"))
    return _locate_package(id)
end

function _absolute_record(record::Dict{String,Any}, manifest_file::String)
    result = deepcopy(record)
    if haskey(result, "path")
        result["path"] = abspath(dirname(manifest_file), result["path"])
    end
    # A local git source is also relative to the environment that recorded it.
    if haskey(result, "repo-url")
        url = result["repo-url"]
        if !occursin(r"^[A-Za-z][A-Za-z0-9+.-]*://|^[^/]+@[^:]+:", url) && !isabspath(url)
            result["repo-url"] = abspath(dirname(manifest_file), url)
        end
    end
    return result
end

function _read_environment(project_file::String)
    project_file = abspath(project_file)
    project = isfile(project_file) ? TOML.parsefile(project_file) : Dict{String,Any}()
    # This loader query honors versioned manifests and workspaces, without
    # Pkg.activate/develop/resolve or EnvCache's depot-usage writes.
    selected = isfile(project_file) ? Base.project_file_manifest_path(project_file) : nothing
    manifest_file = selected === nothing ? joinpath(dirname(project_file), "Manifest.toml") : selected
    raw = isfile(manifest_file) ? TOML.parsefile(manifest_file) : Dict{String,Any}()
    manifest = if haskey(raw, "manifest_format")
        deepcopy(raw)
    else
        entries = Dict{String,Any}(name => value for (name, value) in raw if value isa Vector)
        Dict{String,Any}("manifest_format" => "2.0", "deps" => entries)
    end
    deps = get!(manifest, "deps", Dict{String,Any}())
    for (name, records) in deps
        deps[name] = [_absolute_record(record, manifest_file) for record in records]
    end
    return EnvironmentSnapshot(project_file, manifest_file, project, manifest)
end

function _manifest_record(manifest::Dict{String,Any}, id::Base.PkgId)
    for records in values(get(manifest, "deps", Dict{String,Any}())), record in records
        get(record, "uuid", "") == string(id.uuid) && return record
    end
    return nothing
end

function _project_record(location::PackageLocation)
    project = TOML.parsefile(_project_file(location.root))
    record = Dict{String,Any}("uuid" => string(location.id.uuid), "path" => location.root)
    for key in ("version", "deps", "weakdeps", "extensions")
        haskey(project, key) && (record[key] = deepcopy(project[key]))
    end
    # Match Julia's manifest semantics for packages supporting older Julia with
    # a weak dependency duplicated in [deps]. It must remain optional here.
    if haskey(record, "deps") && haskey(record, "weakdeps")
        for name in keys(record["weakdeps"])
            delete!(record["deps"], name)
        end
    end
    return record
end

function _dependency_ids(record::Dict{String,Any}, owner::Base.PkgId)
    dependencies = get(record, "deps", Dict{String,Any}())
    if dependencies isa AbstractDict
        return Base.PkgId[Base.PkgId(UUIDs.UUID(uuid), name) for (name, uuid) in dependencies]
    end
    return map(dependencies) do name
        id = Base.identify_package(owner, String(name))
        id === nothing && error("cannot resolve locked dependency $name of $(owner.name)")
        id
    end
end

function _add_locked_package!(manifest::Dict{String,Any}, id::Base.PkgId,
                              environments::Dict{String,EnvironmentSnapshot}, seen::Set{UUIDs.UUID})
    id.uuid in seen && return
    push!(seen, id.uuid)
    record = _manifest_record(manifest, id)
    if record === nothing
        location = _locate_package(id)
        environment = location.environment
        if isfile(environment)
            snapshot = get!(environments, environment) do
                _read_environment(environment)
            end
            if get(snapshot.project, "uuid", "") == string(id.uuid)
                record = _project_record(location)
            else
                record = _manifest_record(snapshot.manifest, id)
            end
            if haskey(snapshot.manifest, "registries")
                registries = get!(manifest, "registries", Dict{String,Any}())
                for (name, registry) in snapshot.manifest["registries"]
                    get!(registries, name, deepcopy(registry))
                end
            end
        end
        # Implicit package-directory environments have no manifest record. This
        # preserves their actual loader location, rather than inventing a source.
        record === nothing && (record = _project_record(location))
        record = deepcopy(record)
        if startswith(location.root, Sys.STDLIB * Base.Filesystem.path_separator)
            delete!(record, "path")
        end
        push!(get!(manifest["deps"], id.name, Any[]), record)
    end
    for dependency in _dependency_ids(record, id)
        _add_locked_package!(manifest, dependency, environments, seen)
    end
    return nothing
end

function _validate_tool_compatibility(manifest::Dict{String,Any}, id::Base.PkgId)
    project = TOML.parsefile(_project_file(_locate_package(id).root))
    compat = get(project, "compat", Dict{String,Any}())
    for (name, uuid) in get(project, "deps", Dict{String,Any}())
        haskey(compat, name) || continue
        dependency = Base.PkgId(UUIDs.UUID(uuid), name)
        record = _manifest_record(manifest, dependency)
        record === nothing && error("missing locked tool dependency $name")
        haskey(record, "version") || continue
        version = VersionNumber(record["version"])
        version in Pkg.Types.semver_spec(compat[name]) || throw(ArgumentError(
            "locked $name $version does not satisfy $(id.name)'s $(compat[name]); " *
            "DispatchCheckup will not change the test environment's locked versions"))
    end
    return nothing
end

function _copy_package_tree(source::String, destination::String,
                            ancestors::Dict{String,String}=Dict{String,String}())
    canonical = realpath(source)
    if haskey(ancestors, canonical)
        # Preserve directory cycles inside the private tree rather than pointing
        # back to live source. Finite includes through an alias remain frozen.
        symlink(ancestors[canonical], destination; dir_target=true)
        return destination
    end
    ancestors[canonical] = destination
    try
        mkpath(destination)
        for name in readdir(source)
            name in (".git", ".hg", ".svn") && continue
            input, output = joinpath(source, name), joinpath(destination, name)
            if isdir(input)
                _copy_package_tree(input, output, ancestors)
            elseif isfile(input) && (endswith(lowercase(name), ".jl") || endswith(lowercase(name), ".toml"))
                # Source and metadata are private writable copies, including
                # symlinked source directories. Large assets remain shared.
                cp(input, output; follow_symlinks=true)
                chmod(output, stat(output).mode | 0o200)
            else
                symlink(abspath(input), output)
            end
        end
    finally
        delete!(ancestors, canonical)
    end
    return destination
end

function _source_fingerprint(root::String)
    records = String[]
    for (directory, _, files) in walkdir(root; follow_symlinks=false)
        for file in files
            path = joinpath(directory, file)
            islink(path) && continue
            (endswith(lowercase(file), ".jl") || endswith(lowercase(file), ".toml")) || continue
            digest = open(SHA.sha256, path)
            push!(records, relpath(path, root) * '\0' * bytes2hex(digest))
        end
    end
    return bytes2hex(SHA.sha256(join(sort!(records), '\n')))
end

function _write_toml(path::String, data::Dict{String,Any})
    open(path, "w") do io
        TOML.print(io, data; sorted=true)
    end
    return path
end

function _absolutize_project_sources!(project::Dict{String,Any}, root::String)
    for source in values(get(project, "sources", Dict{String,Any}()))
        source isa AbstractDict || continue
        haskey(source, "path") && (source["path"] = abspath(root, source["path"]))
    end
    # The copied manifest already contains workspace packages. A temporary
    # unnamed project must not acquire another project's workspace root.
    delete!(project, "workspace")
    delete!(project, "manifest")
    return project
end

function _temporary_preferences!(project::Dict{String,Any}, manifest::Dict{String,Any}, target::Base.PkgId)
    preferences = Dict{String,Any}()
    extras = get!(project, "extras", Dict{String,Any}())
    deps = project["deps"]
    for (name, records) in manifest["deps"], record in records
        uuid = UUIDs.UUID(record["uuid"])
        prefs = deepcopy(Base.get_preferences(uuid))
        uuid == target.uuid && merge!(prefs, Dict{String,Any}(
            "dispatch_doctor_mode" => "error", "dispatch_doctor_union_limit" => 1,
            "dispatch_doctor_codegen_level" => "min"))
        isempty(prefs) && continue
        alias = name
        existing = get(deps, alias, get(extras, alias, string(uuid)))
        if existing != string(uuid)
            alias = "DispatchCheckupPreference_" * replace(string(uuid), "-" => "")
        end
        haskey(deps, alias) || (extras[alias] = string(uuid))
        preferences[alias] = prefs
    end
    return preferences
end

function _entry_shim(config_file::String, original::String)
    # Extension entry files execute in Base.__toplevel__, whose import context
    # is not the parent package's dependency context. Resolve the declared helper
    # by UUID without installing a binding into that shared loader module.
    return "let checkup = Base.require(Base.PkgId(Base.UUID($(repr(string(CHECKUP_UUID)))), \"DispatchCheckup\"))\n" *
           "    entry = Base.invokelatest(Base.getglobal, checkup, :_instrument_entry)\n" *
           "    Base.invokelatest(entry, @__MODULE__, $(repr(config_file)), $(repr(original)))\nend\n"
end

function _helper_overlay!(root::String, project::Dict{String,Any}, manifest::Dict{String,Any}, helper::Base.PkgId)
    location = _locate_package(helper)
    destination = joinpath(root, "helper", helper.name)
    _copy_package_tree(location.root, destination)
    entry = joinpath(destination, relpath(location.entry, location.root))
    source = read(entry, String)
    closings = collect(eachmatch(r"(?m)^end\s*#\s*module\s+DispatchCheckup\s*$", source))
    isempty(closings) && error("cannot prepare the isolated DispatchCheckup entrypoint")
    closing = last(closings).offset
    insertion = "include(\"implementation.jl\")\nconst _ISOLATED_EAGER_IMPLEMENTATION = true\n\n"
    write(entry, source[1:closing-1] * insertion * source[closing:end])
    helper_project_file = _project_file(destination)
    helper_project = TOML.parsefile(helper_project_file)
    _absolutize_project_sources!(helper_project, location.root)
    _write_toml(helper_project_file, helper_project)
    record = _manifest_record(manifest, helper)
    provenance = deepcopy(record)
    record["path"] = destination
    for key in ("git-tree-sha1", "repo-url", "repo-rev", "repo-subdir", "pinned", "registries")
        delete!(record, key)
    end
    get!(project, "sources", Dict{String,Any}())[helper.name] = Dict("path" => destination)
    return (; root=destination, entry, provenance)
end

function _build_environment(target::PackageLocation, test_entry::String,
                            exclusions::Vector{String}; require_all::Bool=false,
                            report::Union{Nothing,String}=nothing)
    root = mktempdir(; prefix="dispatchcheckup-")
    try
        environment_root = mkpath(joinpath(root, "environment"))
        depot = mkpath(joinpath(root, "depot"))
        snapshot_root = joinpath(root, "snapshot", target.id.name)
        overlay_root = joinpath(root, "overlay", target.id.name)
        _copy_package_tree(target.root, snapshot_root)
        _copy_package_tree(snapshot_root, overlay_root)

        active = something(Base.active_project(), joinpath(pwd(), "Project.toml"))
        snapshot = _read_environment(active)
        project = deepcopy(snapshot.project)
        manifest = deepcopy(snapshot.manifest)
        environments = Dict(snapshot.project_file => snapshot)
        seen = Set{UUIDs.UUID}()
        helper = Base.PkgId(CHECKUP_UUID, "DispatchCheckup")
        doctor = Base.PkgId(DOCTOR_UUID, "DispatchDoctor")
        for id in (target.id, helper, doctor)
            _add_locked_package!(manifest, id, environments, seen)
        end
        _validate_tool_compatibility(manifest, helper)
        _validate_tool_compatibility(manifest, doctor)

        original_name = get(project, "name", nothing)
        original_uuid = get(project, "uuid", nothing)
        deps = get!(project, "deps", Dict{String,Any}())
        if original_name !== nothing && original_uuid !== nothing
            deps[original_name] = original_uuid
            _add_locked_package!(manifest, Base.PkgId(UUIDs.UUID(original_uuid), original_name), environments, seen)
        end
        for key in ("name", "uuid", "version", "authors")
            delete!(project, key)
        end
        for id in (target.id, helper, doctor)
            deps[id.name] = string(id.uuid)
        end
        _absolutize_project_sources!(project, dirname(snapshot.project_file))
        get!(project, "sources", Dict{String,Any}())[target.id.name] = Dict("path" => overlay_root)
        helper_overlay = _helper_overlay!(root, project, manifest, helper)
        delete!(manifest, "project_hash")
        manifest["julia_version"] = string(VERSION)

        overlay_project_path = _project_file(overlay_root)
        overlay_project = TOML.parsefile(overlay_project_path)
        _absolutize_project_sources!(overlay_project, target.root)
        overlay_deps = get!(overlay_project, "deps", Dict{String,Any}())
        overlay_compat = get!(overlay_project, "compat", Dict{String,Any}())
        get!(overlay_project, "sources", Dict{String,Any}())[helper.name] = Dict("path" => helper_overlay.root)
        target_record = _manifest_record(manifest, target.id)
        target_provenance = deepcopy(target_record)
        target_record["path"] = overlay_root
        for key in ("git-tree-sha1", "repo-url", "repo-rev", "repo-subdir", "pinned", "registries")
            delete!(target_record, key)
        end
        target_deps = Dict(id.name => string(id.uuid) for id in _dependency_ids(target_record, target.id))
        for id in (helper, doctor)
            overlay_deps[id.name] = string(id.uuid)
            target_deps[id.name] = string(id.uuid)
            version = get(_manifest_record(manifest, id), "version", nothing)
            version === nothing || (overlay_compat[id.name] = string(version))
        end
        target_record["deps"] = target_deps
        _write_toml(overlay_project_path, overlay_project)

        preferences = _temporary_preferences!(project, manifest, target.id)
        project_file = _write_toml(joinpath(environment_root, "Project.toml"), project)
        _write_toml(joinpath(environment_root, "Manifest.toml"), manifest)
        _write_toml(joinpath(environment_root, "LocalPreferences.toml"), preferences)

        extensions = String[]
        for name in keys(get(overlay_project, "extensions", Dict{String,Any}()))
            candidates = (joinpath(target.root, "ext", name * ".jl"),
                          joinpath(target.root, "ext", name, name * ".jl"))
            index = findfirst(isfile, candidates)
            index === nothing && error("extension $name has no source entrypoint")
            push!(extensions, candidates[index])
        end
        config_file = joinpath(root, "config.toml")
        for original in [target.entry; extensions]
            destination = joinpath(overlay_root, relpath(original, target.root))
            write(destination, _entry_shim(config_file, original))
        end
        bootstrap = joinpath(root, "launch.jl")
        write(bootstrap, "import DispatchCheckup\n" *
              "isdefined(DispatchCheckup, :_ISOLATED_EAGER_IMPLEMENTATION) || error(\"DispatchCheckup loaded an unisolated helper cache\")\n" *
              "DispatchCheckup._child_main($(repr(config_file)))\n")
        token = string(UUIDs.uuid4())
        original_load_path = Base.load_path()
        # Keep the active-project marker rather than a literal path: package
        # tests can legitimately activate another environment, and tools such
        # as Aqua launch precompile workers with their own --project argument.
        child_load_path = ["@"; filter(!=(snapshot.project_file), original_load_path)]
        config = Dict{String,Any}(
            "format_version" => 1, "token" => token,
            "target_name" => target.id.name, "target_uuid" => string(target.id.uuid),
            "original_root" => target.root, "overlay_root" => overlay_root,
            "snapshot_root" => snapshot_root, "main_entry" => target.entry,
            "extension_entries" => extensions, "unstable" => exclusions,
            "require_all" => require_all, "codegen_level" => "min", "union_limit" => 1,
            "project_file" => project_file, "bootstrap_file" => bootstrap,
            "test_entry" => test_entry, "test_entry_digest" => bytes2hex(open(SHA.sha256, test_entry)),
            "program_file" => PROGRAM_FILE, "working_directory" => pwd(),
            "arguments" => copy(ARGS), "load_path" => child_load_path,
            "snapshot_digest" => _source_fingerprint(snapshot_root),
            "overlay_digest" => _source_fingerprint(overlay_root),
            "helper_overlay_root" => helper_overlay.root,
            "helper_entry" => helper_overlay.entry,
            "helper_overlay_digest" => _source_fingerprint(helper_overlay.root),
            "helper_provenance" => helper_overlay.provenance,
            "target_provenance" => target_provenance,
            "doctor_provenance" => deepcopy(_manifest_record(manifest, doctor)),
            "report_file" => joinpath(root, "report.toml"),
        )
        report === nothing || (config["report_destination"] = report)
        _write_toml(config_file, config)
        digest = bytes2hex(open(SHA.sha256, config_file))
        return OverlayEnvironment(root, project_file, config_file, bootstrap, depot,
                                  target, overlay_root, snapshot_root, token, digest)
    catch
        rm(root; recursive=true, force=true)
        rethrow()
    end
end

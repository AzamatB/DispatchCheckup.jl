# What the overlay shims do to the package's own files: the include mapexpr, the
# `unstable=` matcher, and the static scan that checks every entry matches something.

# One `unstable=` entry: `:foo`, `Symbol("Mod.foo")` or `:foo => "src/file.jl:LINE"`.
struct Exclusion
    name::String       # as written, e.g. "foo", "MyPackage.Sub.foo" or "Base.:+"
    location::String   # "src/file.jl:LINE", or "" for every location
    qualifier::String  # the part of `name` before its last dot ("" for a bare name)
    final::String      # the function name itself (`+` for "Base.:+" or "Base.:(+)")
    file::String       # `location`'s file, normalized
    line::Int          # `location`'s line
end

function Exclusion(name::String, location::String)
    m = match(r"^([^.]+(?:\.[^.]+)*)\.(.+)$", name)
    qualifier, final = m === nothing ? ("", name) :
                       (String(m[1]), String(strip(lstrip(m[2], ':'), ['(', ')'])))
    file, line = "", 0
    if !isempty(location)
        l = match(r"^(.+):(\d+)$", location)
        l === nothing && throw(ArgumentError(
            "an unstable= location must look like \"src/file.jl:LINE\", got $(repr(location))"))
        file, line = normpath(l[1]), parse(Int, l[2])
    end
    return Exclusion(name, location, qualifier, final, file, line)
end

_exclusion(e::Symbol) = Exclusion(String(e), "")
_exclusion(e::Pair{Symbol,<:AbstractString}) = Exclusion(String(e.first), String(e.second))
_exclusion(e) = throw(ArgumentError(
    "unstable= entries are Symbols or `:name => \"src/file.jl:LINE\"` pairs, got $(repr(e))"))
_exclusions(unstable) = Exclusion[_exclusion(e) for e in
                                  (unstable isa Union{Symbol,Pair} ? (unstable,) : unstable)]

_text(e::Exclusion) = isempty(e.location) ? e.name : "$(e.name) => $(e.location)"

# The configuration of a checked package, as embedded in its shims.
const Config = @NamedTuple{id::Base.PkgId, root::String, unstable::Vector{Exclusion},
                           mode::String, union_limit::Int}
const CONFIG = Ref{Union{Nothing,Config}}(nothing)

# The written name ("Base.getindex") and final name ("getindex") of a definition's callee.
_names(s::Symbol) = (String(s), String(s))
_names(q::QuoteNode) = _names(q.value)
function _names(ex::Expr)
    ex.head === :. && length(ex.args) == 2 || return ("", "")
    (outer, _), (inner, final) = _names(ex.args[1]), _names(ex.args[2])
    return isempty(outer) || isempty(inner) ? ("", "") : ("$outer.$inner", final)
end
_names(_) = ("", "")

_first_line(ex::LineNumberNode) = ex
_first_line(ex::Expr) = for a in ex.args
    (line = _first_line(a)) === nothing || return line
end
_first_line(_) = nothing

# The definition at the end of a chain of macro calls (`@inline f(x) = ...`), or `ex`.
_unwrap(ex) = Meta.isexpr(ex, :macrocall) && length(ex.args) > 2 ? _unwrap(ex.args[end]) : ex

# A function definition as DispatchDoctor recognizes one (the same test as `@stable`):
# where it is (module path, file relative to the package root, first line) and its name.
function _definition(ex, modpath::String, root::String)
    isdef(ex) && @capture(longdef1(ex), function (fcall_ | fcall_) body_ end) || return nothing
    name = try
        get(splitdef(ex), :name, nothing)
    catch
        nothing  # a form that DispatchDoctor leaves alone
    end
    written, final = _names(name)
    line = _first_line(ex)
    file = line === nothing || line.file === nothing ? "" : relpath(String(line.file), root)
    return (; modpath, written, final, file, line = line === nothing ? 0 : line.line)
end

function _excludes(e::Exclusion, d)
    named = d.final == e.final && (isempty(e.qualifier) || d.modpath == e.qualifier ||
                                   d.written == "$(e.qualifier).$(e.final)")
    return named && (isempty(e.file) || (d.file == e.file && d.line == e.line))
end

# Rebuild `ex`, the code of module `modpath`, replacing each node `n` for which
# `f(n, modpath)` returns something other than `nothing`. Like DispatchDoctor, it does
# not look into quotes, macro definitions or `global`/`local` declarations.
function _walk(f, ex, modpath::String)
    ex isa Expr || return ex
    ex.head in (:quote, :macro, :global, :local) && return ex
    if ex.head === :module
        name = String(ex.args[end-1])
        inner = isempty(modpath) ? name : "$modpath.$name"
        return Expr(:module, ex.args[1:end-1]..., _walk(f, ex.args[end], inner))
    end
    new = f(ex, modpath)
    new === nothing || return new
    return Expr(ex.head, Any[_walk(f, a, modpath) for a in ex.args]...)
end

# `include([mapper,] path)`, `Base.include([mapper,] mod, path)` (or `Core.include`) and
# `Mod.include([mapper,] path)`, as `(mapper, module, path)` (`nothing` for anything else).
function _include_call(ex::Expr)
    ex.head === :call && length(ex.args) > 1 && !any(a -> Meta.isexpr(a, :...), ex.args) ||
        return nothing
    f, args = ex.args[1], ex.args[2:end]
    if !(f in (:(Base.include), :(Core.include)))  # (these two take the module first)
        f === :include || Meta.isexpr(f, :.) && f.args[2] == QuoteNode(:include) || return nothing
        mod = f === :include ? Expr(:macrocall, GlobalRef(Base, Symbol("@__MODULE__")), nothing) :
              f.args[1]
        args = [args[1:end-1]; mod; args[end]]
    end
    return length(args) == 2 ? (identity, args...) : length(args) == 3 ? (args...,) : nothing
end

# A call of the macro `name` (`@__DIR__`, say), or of `Base.name`.
_ismacro(ex, name::Symbol) = Meta.isexpr(ex, :macrocall) && ex.args[1] in
                             (name, GlobalRef(Base, name), Expr(:., :Base, QuoteNode(name)))

# Apply DispatchDoctor to one top-level expression `ex` of module `mod`:
# (1) wrap the definitions selected by unstable= in `@unstable`, (2) send nested include
# calls through `_include` (so that this applies to the included files too), then
# (3) stabilize `ex` exactly as `@stable` would in `mod`.
function _transform(mod::Module, ex, source::Union{LineNumberNode,Nothing} = nothing)
    cfg = CONFIG[]
    cfg === nothing && error("DispatchCheckup: no checked package is being loaded")
    _check_options(mod, cfg)
    ex = _walk(ex, join(fullname(mod), '.')) do e, modpath
        d = _definition(_unwrap(e), modpath, cfg.root)
        if d !== nothing  # (function bodies run later; their includes are left alone)
            any(x -> _excludes(x, d), cfg.unstable) || return e
            # around any macros too, as `@generated` and others need a bare definition
            return Expr(:macrocall, GlobalRef(DispatchDoctor, Symbol("@unstable")),
                        something(_first_line(e), LineNumberNode(0)), e)
        end
        call = _include_call(e)
        return call === nothing ? nothing : Expr(:call, _include, call...)
    end
    return DispatchDoctor.stabilize_expression(mod, ex; default_mode = cfg.mode,
        default_codegen_level = "debug", default_union_limit = cfg.union_limit,
        source_info = source)
end

_include(mapper, mod::Module, path::AbstractString) =
    Base.include(ex -> _transform(mod, Base.invokelatest(mapper, ex)), mod, path)
# (`x.include(...)` where `x` is not a module: the call as it was written)
_include(mapper, x, path) = mapper === identity ? x.include(path) : x.include(mapper, path)

# Check (2): DispatchDoctor resolves the requested options for `mod` (a module, or the
# package's UUID), so that no preference (such as `dispatch_doctor_mode = "disable"`)
# switches the checks off.
function _check_options(mod::Union{Module,Base.UUID}, cfg::Config)
    wanted = (mode = cfg.mode, union_limit = cfg.union_limit, codegen_level = "debug")
    found = DispatchDoctor.stabilization_options(mod; default_mode = cfg.mode,
        default_codegen_level = "debug", default_union_limit = cfg.union_limit)
    found == wanted || error("DispatchCheckup: DispatchDoctor would use $found in ",
                             mod isa Module ? mod : cfg.id.name, ", not the requested $wanted")
    return nothing
end

# Mark each statement of the package's module (the entry file runs in Base.__toplevel__),
# so that it is transformed inside that module, after the statements before it have run.
# The module starts with a hidden module whose `__init__`, the first to run, points Base's
# record of the package at the original `entry` when it is loaded from a precompiled image.
macro _checked(ex)
    return esc(_transform(__module__, ex, __source__))
end

function _mark(ex, pkg::Base.PkgId, entry::String)
    ex isa Expr && ex.head !== :quote || return ex
    ex.head === :module || return Expr(ex.head, Any[_mark(a, pkg, entry) for a in ex.args]...)
    init = :(__init__() = $(GlobalRef(@__MODULE__, :_origin!))($pkg, $entry))
    line, body = LineNumberNode(0), Any[Expr(:module, false, Symbol("#DispatchCheckup"), Expr(:block, init))]
    for a in ex.args[end].args
        a isa LineNumberNode && (line = a)
        push!(body, a isa LineNumberNode ? a :
                    Expr(:macrocall, GlobalRef(@__MODULE__, Symbol("@_checked")), line, a))
    end
    return Expr(:module, ex.args[1:end-1]..., Expr(:block, body...))
end

# Where Base loaded each checked package from, before `_origin!` pointed it at the original.
const LOADED_FROM = Dict{Base.PkgId,Union{Nothing,String}}()

function _origin!(pkg::Base.PkgId, entry::String)
    @lock Base.require_lock begin  # so that pkgdir and pathof report the original checkout
        origin = get(Base.pkgorigins, pkg, nothing)
        origin === nothing || origin.path == entry || (LOADED_FROM[pkg] = origin.path)
        origin === nothing || (origin.path = entry)
    end
    return nothing
end

# Called by an overlay shim: load the original `entry` of `pkg` (the checked package
# `target` or one of its extensions) in place, with DispatchDoctor applied.
function _load_checked(loader::Module, pkg::Base.PkgId, target::Base.PkgId, entry::String,
                       root::String, unstable::Vector{Tuple{String,String}}, mode::String,
                       union_limit::Int)
    cfg = Config((target, root, [Exclusion(n, l) for (n, l) in unstable], mode, union_limit))
    CONFIG[] === nothing || CONFIG[] == cfg ||
        error("DispatchCheckup: $(pkg.name) is configured differently from this run")
    CONFIG[] = cfg
    _origin!(pkg, entry)  # (for the package's own top-level code)
    return Base.include(ex -> _mark(ex, pkg, entry), loader, entry)
end

# Check (3), at activation: parse the package from its entry files, following the include
# calls whose path and module can be worked out, and return every definition found (for the
# matcher and suggestions) and the include calls that could not be followed.
function _scan(root::String, entries)
    found, skipped, seen = [], String[], Set{Tuple{String,String}}()
    function walk(ex, file, modpath)
        _walk(ex, modpath) do e, m
            d = _definition(_unwrap(e), m, root)
            d === nothing || (push!(found, d); return e)
            if Meta.isexpr(e, :for) && Meta.isexpr(e.args[1], :(=))  # for f in ("a.jl", ...)
                var, values = e.args[1].args
                if Meta.isexpr(values, (:tuple, :vect)) && all(v -> v isa String, values.args)
                    foreach(v -> walk(postwalk(x -> x === var ? v : x, e.args[2]), file, m), values.args)
                    return e
                end
            end
            call = _include_call(e)
            call === nothing && return nothing
            path, inner = _path(call[3], file), _modpath(call[2], m)
            path === nothing || inner === nothing ?
                push!(skipped, "$(relpath(file, root)): " * replace(string(e), r"#=.*?=# " => "")) :
                read_file(normpath(dirname(file), path), inner)
            return e
        end
    end
    function read_file(file, modpath)
        ((file, modpath) in seen || !isfile(file)) && return
        push!(seen, (file, modpath))
        walk(Meta.parseall(read(file, String); filename = file), file, modpath)
    end
    foreach(entry -> read_file(entry, ""), entries)
    return found, skipped
end

# A path built from strings, `@__DIR__`, `@__FILE__`, `joinpath`, `dirname` and string
# interpolation, relative to the including `file` (`nothing` for anything else).
function _path(p, file)
    p isa String && return p
    _ismacro(p, Symbol("@__DIR__")) && return dirname(file)
    _ismacro(p, Symbol("@__FILE__")) && return file
    Meta.isexpr(p, :string) || Meta.isexpr(p, :call) && length(p.args) > 1 || return nothing
    parts = map(a -> _path(a, file), p.head === :call ? p.args[2:end] : p.args)
    any(isnothing, parts) && return nothing
    p.head === :string && return string(parts...)
    p.args[1] === :joinpath && return joinpath(parts...)
    p.args[1] === :dirname && length(parts) == 1 && return dirname(only(parts))
    return nothing
end

# The module path that an include call's module argument names inside module `m`: `m`
# itself (`@__MODULE__`), an enclosing module or a submodule (`nothing` for anything else).
function _modpath(mod, m::String)
    _ismacro(mod, Symbol("@__MODULE__")) && return m
    mod isa Symbol || return nothing
    parts = split(m, '.')
    i = findlast(==(String(mod)), parts)
    return i !== nothing ? join(parts[1:i], '.') : isempty(m) ? String(mod) : "$m.$mod"
end

function _check_matches(root::String, entries, unstable::Vector{Exclusion})
    found, skipped = _scan(root, entries)
    missed = filter(e -> !any(d -> _excludes(e, d), found), unstable)
    isempty(missed) && return nothing
    names = unique!([s for d in found if !isempty(d.final) for s in
                     (d.final, "$(d.modpath).$(d.final)", d.written, "$(d.final) => $(d.file):$(d.line)")])
    lines = map(missed) do e
        near = first(sort(names; by = n -> _distance(_text(e), n)), 3)
        "  $(_text(e))" * (isempty(near) ? "" : "   (nearest: $(join(near, ", ")))")
    end
    error("DispatchCheckup: these unstable= entries match no definition in the package's " *
          "sources:\n" * join(lines, '\n') * (isempty(skipped) ? "" : "\nThese include calls " *
          "could not be followed, so their files were not searched:\n  " * join(skipped, "\n  ")))
end

# Levenshtein distance, for the suggestions above.
function _distance(a::AbstractString, b::AbstractString)
    b = collect(b)
    d = collect(0:length(b))
    for (i, x) in enumerate(a)
        previous, d[1] = d[1], i
        for (j, y) in enumerate(b)
            previous, d[j+1] = d[j+1], min(d[j+1] + 1, d[j] + 1, previous + (x != y))
        end
    end
    return d[end]
end

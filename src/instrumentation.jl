# Loaded only inside the lazy Implementation module. No loader methods are replaced.

struct InstrumentationRecord
    kind::Symbol
    name::String
    file::String
    line::Int
    reason::String
end

struct IncludeObservation
    scope::String
    path::String
    instrumented::Bool
end

mutable struct InstrumentationContext
    config_file::String
    target::String
    target_uuid::UUID
    original_root::String
    overlay_root::String
    snapshot_root::String
    main_entry::String
    require_all::Bool
    codegen_level::String
    union_limit::Int
    exclusions::Dict{String,Int}
    files::Set{String}
    entries::Set{String}
    modules::Set{Module}
    checked_modules::Set{Module}
    records::Vector{InstrumentationRecord}
    shim_paths::Set{String}
    extension_names::Set{String}
    pending_includes::Dict{Tuple{Task,Module,String},Int}
    observed_includes::Vector{IncludeObservation}
    lock::ReentrantLock
end

const _INSTRUMENTATION_CONTEXTS = Dict{String,InstrumentationContext}()
const _INSTRUMENTATION_LOCK = ReentrantLock()

function _instrumentation_context(config_file::AbstractString)
    config_file = abspath(config_file)
    lock(_INSTRUMENTATION_LOCK) do
        get!(_INSTRUMENTATION_CONTEXTS, config_file) do
            config = TOML.parsefile(config_file)
            get(config, "format_version", 0) == 1 || throw(ArgumentError("unsupported instrumentation config format"))
            target = String(config["target_name"])
            exclusions = Dict{String,Int}()
            for value in get(config, "unstable", String[])
                name = String(value)
                isempty(name) && throw(ArgumentError("an unstable exclusion cannot be empty"))
                exclusions[occursin('.', name) ? name : target * "." * name] = 0
            end
            entries = [String(config["main_entry"]); String.(get(config, "extension_entries", String[]))]
            shims = Set(abspath(joinpath(config["overlay_root"], relpath(entry, config["original_root"]))) for entry in entries)
            extension_names = Set(splitext(basename(entry))[1] for entry in entries[2:end])
            InstrumentationContext(config_file, target, UUID(config["target_uuid"]),
                realpath(config["original_root"]), realpath(config["overlay_root"]),
                realpath(config["snapshot_root"]), abspath(config["main_entry"]),
                get(config, "require_all", false), get(config, "codegen_level", "debug"),
                get(config, "union_limit", 1), exclusions, Set{String}(), Set{String}(),
                Set{Module}(), Set{Module}(), InstrumentationRecord[], shims, extension_names,
                Dict{Tuple{Task,Module,String},Int}(), IncludeObservation[], ReentrantLock())
        end
    end
end

_inside_root(path, root) = path == root || startswith(path, root * string(Base.Filesystem.path_separator))

function _owned_module(ctx, mod)
    name = string(mod)
    (name == ctx.target || startswith(name, ctx.target * ".")) && return true
    mod in ctx.modules && return true
    return any(root -> name == root || startswith(name, root * "."), ctx.extension_names)
end

function _expect_include!(ctx, mod, path)
    lock(ctx.lock) do
        key = (current_task(), mod, abspath(path))
        ctx.pending_includes[key] = get(ctx.pending_includes, key, 0) + 1
    end
    return path
end

function start_include_observer!(config_file::AbstractString)
    ctx = _instrumentation_context(config_file)
    observer = function(mod, path)
        path = abspath(path)
        lock(ctx.lock) do
            key = (current_task(), mod, path)
            expected = get(ctx.pending_includes, key, 0)
            original = _original_path(ctx, path)
            source_path = _inside_root(original, dirname(ctx.main_entry)) ||
                _inside_root(original, joinpath(ctx.original_root, "ext"))
            relevant = expected > 0 || _owned_module(ctx, mod) || source_path || path in ctx.shim_paths
            relevant || return nothing
            if expected > 0
                expected == 1 ? delete!(ctx.pending_includes, key) : (ctx.pending_includes[key] = expected - 1)
            end
            # The loader must first read its small entry shim. That shim then
            # invokes instrument_entry, which registers the mapped snapshot read.
            covered = expected > 0 || path in ctx.shim_paths
            push!(ctx.observed_includes, IncludeObservation(string(mod), original, covered))
        end
        return nothing
    end
    # This is a scoped observer, not an include replacement: callback return
    # values do not affect Julia's loader, mapper, or evaluation order.
    push!(Base.include_callbacks, observer)
    return observer
end

function stop_include_observer!(observer)
    filter!(callback -> callback !== observer, Base.include_callbacks)
    return nothing
end

function _validate_include_observations!(ctx)
    uncovered = filter(event -> !event.instrumented, ctx.observed_includes)
    isempty(uncovered) || throw(ArgumentError("included source bypassed instrumentation: " *
        join(unique(event.path * " in " * event.scope for event in uncovered), ", ")))
    isempty(ctx.pending_includes) || throw(ArgumentError("a prepared instrumented include did not reach Julia's loader"))
    return nothing
end

function _original_path(ctx::InstrumentationContext, path::AbstractString)
    path = abspath(path)
    for root in (ctx.snapshot_root, ctx.overlay_root)
        _inside_root(path, root) && return normpath(joinpath(ctx.original_root, relpath(path, root)))
    end
    return path
end

function _snapshot_path(ctx::InstrumentationContext, path::AbstractString)
    path = isabspath(path) ? normpath(path) : normpath(joinpath(Base.source_dir(), path))
    original = _original_path(ctx, path)
    _inside_root(original, ctx.original_root) || throw(ArgumentError(
        "included source escapes the instrumented package: $original"))
    snapshot = normpath(joinpath(ctx.snapshot_root, relpath(original, ctx.original_root)))
    isfile(snapshot) || throw(ArgumentError("included source is absent from the snapshot: $original"))
    _inside_root(realpath(snapshot), ctx.snapshot_root) || throw(ArgumentError(
        "included source symlink escapes the snapshot: $original"))
    return snapshot
end

function _record!(ctx, kind, name, file, line, reason="")
    lock(ctx.lock) do
        push!(ctx.records, InstrumentationRecord(kind, String(name), String(file), Int(line), String(reason)))
    end
    return nothing
end

function _source_lines(ctx, ex)
    if ex isa LineNumberNode
        file = ex.file
        return file === nothing ? ex : LineNumberNode(ex.line,
            Symbol(isabspath(String(file)) ? _original_path(ctx, String(file)) : String(file)))
    elseif ex isa Expr
        return Expr(ex.head, map(arg -> _source_lines(ctx, arg), ex.args)...)
    end
    return ex
end

function _macro_name(ex)
    ex isa Symbol && return ex
    ex isa GlobalRef && return ex.name
    ex isa QuoteNode && return _macro_name(ex.value)
    ex isa Expr && ex.head == :. && return _macro_name(last(ex.args))
    return nothing
end

function _syntax_name(ex)
    ex isa Symbol && return String(ex)
    ex isa GlobalRef && return string(ex.mod, '.', ex.name)
    ex isa QuoteNode && return _syntax_name(ex.value)
    ex isa Expr && ex.head === :curly && return _syntax_name(first(ex.args))
    if ex isa Expr && ex.head == :.
        left, right = _syntax_name(ex.args[1]), _syntax_name(ex.args[end])
        return isempty(left) || isempty(right) ? "" : left * "." * right
    end
    return ""
end

function _definition(ex)
    while ex isa Expr && ex.head == :macrocall && !isempty(ex.args)
        ex = last(ex.args)
    end
    ex isa Expr || return nothing
    MacroTools.isdef(ex) || return nothing
    try
        # Normalize the declaration only. Recursive longdef rewrites typed
        # arrow closures inside the body into invalid anonymous signatures.
        return MacroTools.splitdef(ex)
    catch error
        error isa InterruptException && rethrow()
        return nothing
    end
end

function _definition_hint(ex, scope)
    def = _definition(ex)
    def === nothing && return scope * ".<generated>"
    name = _syntax_name(get(def, :name, :anonymous_function))
    isempty(name) && return scope * ".<callable>"
    return occursin('.', name) ? name : scope * "." * name
end

function _binding(mod::Module, ex)
    if ex isa Symbol
        return isdefined(mod, ex) ? Base.invokelatest(getglobal, mod, ex) : nothing
    elseif ex isa GlobalRef
        return isdefined(ex.mod, ex.name) ? Base.invokelatest(getglobal, ex.mod, ex.name) : nothing
    elseif ex isa Expr && ex.head == :.
        owner = _binding(mod, ex.args[1])
        name = ex.args[end] isa QuoteNode ? ex.args[end].value : ex.args[end]
        return owner isa Module && name isa Symbol && isdefined(owner, name) ? Base.invokelatest(getglobal, owner, name) : nothing
    end
    return nothing
end

function _generic_name(mod::Module, ex, fallback::String)
    def = _definition(ex)
    def === nothing && return fallback
    name = get(def, :name, nothing)
    value = _binding(mod, name)
    if value isa Function || value isa DataType || value isa UnionAll
        owner = parentmodule(value)
        # A visible foreign generic may be a weak export that this declaration
        # shadows. Only that case needs a scan for an explicit local/imported
        # binding; new names and established owned generics take the fast path.
        established = !(name isa Symbol) || owner === mod ||
            name in names(mod; all=true, imported=true)
        established && return string(owner, '.', nameof(value))
    end
    spelling = _syntax_name(name)
    return isempty(spelling) ? fallback : occursin('.', spelling) ? spelling : string(mod, '.', spelling)
end

function _target_module(ctx, mod::Module)
    candidate = mod
    while true
        string(candidate) == ctx.target && return candidate
        parent = parentmodule(candidate)
        parent === candidate && break
        candidate = parent
    end
    for candidate in ctx.modules
        string(candidate) == ctx.target && return candidate
    end
    return get(Base.loaded_modules, Base.PkgId(ctx.target_uuid, ctx.target), nothing)
end

function _canonical_exclusion(ctx, mod, key)
    prefix = ctx.target * "."
    startswith(key, prefix) || return key
    value = _target_module(ctx, mod)
    value isa Module || return key
    for part in split(chopprefix(key, prefix), '.')
        value isa Module || return key
        name = Symbol(part)
        isdefined(value, name) || return key
        value = Base.invokelatest(getglobal, value, name)
    end
    if value isa Function || value isa DataType || value isa UnionAll
        return string(parentmodule(value), '.', nameof(value))
    end
    return key
end

function _excluded!(ctx, name, fallback, mod::Module)
    lock(ctx.lock) do
        # Resolve an existing generic's owner first (including imported extension
        # methods), but retain an explicitly named source binding as an alias.
        found = false
        aliases = startswith(fallback, string(mod) * ".") ? (name, fallback) : (name,)
        owned = _owned_module(ctx, mod)
        for key in keys(ctx.exclusions)
            if key in aliases || (owned && _canonical_exclusion(ctx, mod, key) == name)
                ctx.exclusions[key] += 1
                found = true
            end
        end
        found
    end
end

function _effective_preference(mod, key, default)
    try
        return Preferences.load_preference(mod, key, default)
    catch error
        # Standalone modules used by focused tests have no package preferences.
        Base.PkgId(Base.moduleroot(mod)).uuid === nothing || rethrow()
        return default
    end
end

function _check_preferences(ctx, mod)
    for (key, expected) in (("dispatch_doctor_mode", "error"),
                            ("dispatch_doctor_union_limit", ctx.union_limit),
                            ("dispatch_doctor_codegen_level", ctx.codegen_level))
        value = _effective_preference(mod, key, expected)
        value == expected || throw(ArgumentError(
            "DispatchDoctor preference $key for $mod is $(repr(value)); expected $(repr(expected))"))
    end
end

function _stable_expression(ctx, ex, line)
    Expr(:macrocall, GlobalRef(DispatchDoctor, Symbol("@stable")), line,
         Expr(:(=), :default_mode, "error"),
         Expr(:(=), :default_codegen_level, ctx.codegen_level),
         Expr(:(=), :default_union_limit, ctx.union_limit), ex)
end

# DispatchDoctor 0.4.29 emits an unqualified ! in its generated checker.
# A baremodule need not import Base. Qualify that wrapper-only helper without
# changing either copy of the user's original body.
function _qualify_generated_negation(ex)
    ex isa Expr || return ex
    ex.head == :quote && return ex
    args = map(_qualify_generated_negation, ex.args)
    ex.head == :call && !isempty(args) && args[1] === :! && (args[1] = GlobalRef(Base, :!))
    return Expr(ex.head, args...)
end

function _qualify_doctor_wrapper(ex, wanted)
    ex isa Expr || return ex
    if ex.head == :function || (ex.head == :(=) && MacroTools.isdef(ex))
        def = _definition(ex)
        if def !== nothing && _syntax_name(get(def, :name, nothing)) == wanted
            body = def[:body]
            if body isa Expr && body.head === :block
                # The final expression is DispatchDoctor's caller/original body.
                # Only the preceding generated checker needs Base's negation.
                def[:body] = Expr(:block,
                    map(_qualify_generated_negation, body.args[1:end-1])..., last(body.args))
            end
            return MacroTools.combinedef(def)
        end
        return ex
    end
    return Expr(ex.head, map(arg -> _qualify_doctor_wrapper(arg, wanted), ex.args)...)
end

# Base.map switches to a dynamically allocated buffer for long tuples. A checker
# must preserve the argument-type tuple even for kernels with many arguments.
# Keep DispatchDoctor's Type/Val handling and build the tuple at its known size.
@generated function _specializing_types(args::T) where {T<:Tuple}
    count = try
        fieldcount(T)
    catch
        # An abstract, unbounded tuple has no statically known signature.
        return :(map(DispatchDoctor.specializing_typeof, args))
    end
    elements = [Expr(:call, GlobalRef(DispatchDoctor, :specializing_typeof),
                     Expr(:call, GlobalRef(Core, :getfield), :args, index)) for index in 1:count]
    return Expr(:block, Expr(:meta, :inline), Expr(:tuple, elements...))
end

@inline function _specializing_keywords(kwargs::NamedTuple{Keys}) where {Keys}
    NamedTuple{Keys,Tuple{_specializing_types(values(kwargs))...}}
end

_callee_value(callee) = callee isa GlobalRef && isdefined(callee.mod, callee.name) ?
    Base.invokelatest(getglobal, callee.mod, callee.name) : callee

function _specialize_doctor_arguments(ex)
    ex isa Expr || return ex
    ex.head === :quote && return ex
    args = map(_specialize_doctor_arguments, ex.args)
    if ex.head === :call && !isempty(args)
        value = _callee_value(args[1])
        if value === DispatchDoctor._Utils.map_specializing_typeof
            tuple = length(args) == 2 ? args[2] : nothing
            if tuple isa Expr && tuple.head === :tuple &&
               !any(arg -> arg isa Expr && arg.head === :..., tuple.args)
                # Preserve Type{T} before tuple construction can widen it to
                # DataType. Known argument lists need no mapping helper.
                return Expr(:tuple, (Expr(:call, GlobalRef(DispatchDoctor, :specializing_typeof), arg)
                                     for arg in tuple.args)...)
            end
            args[1] = GlobalRef(@__MODULE__, :_specializing_types)
        end
        if value === DispatchDoctor._Utils._promote_op && length(args) == 5 &&
           (_callee_value(args[2]) === Core.kwcall || args[2] == :(Core.kwcall))
            keyword_type = args[3]
            if keyword_type isa Expr && keyword_type.head === :call &&
               length(keyword_type.args) == 2 &&
               (keyword_type.args[1] === :typeof || _callee_value(keyword_type.args[1]) === typeof)
                args[3] = Expr(:call, GlobalRef(@__MODULE__, :_specializing_keywords), keyword_type.args[2])
            end
        end
    end
    return Expr(ex.head, args...)
end

function _restore_doctor_sources(ex, original, line::LineNumberNode)
    ex isa Expr || return ex
    if MacroTools.isdef(ex)
        generated = _definition(ex)
        generated === nothing && return ex
        wanted = _syntax_name(get(original, :name, nothing))
        name = get(generated, :name, nothing)
        if name isa Symbol && startswith(String(name), "##" * wanted * "_simulator#")
            # Native debug codegen strips all source nodes from the simulator,
            # including macro locations required by command literals and @__DIR__.
            generated[:body] = deepcopy(original[:body])
        elseif _syntax_name(name) == wanted
            body = generated[:body]
            generated[:body] = body isa Expr && body.head === :block ?
                Expr(:block, line, body.args...) : Expr(:block, line, body)
        else
            return ex
        end
        return MacroTools.combinedef(generated)
    end
    return Expr(ex.head, map(arg -> _restore_doctor_sources(arg, original, line), ex.args)...)
end

function _expand_stable(ctx, mod, definition, line)
    expanded = _specialize_doctor_arguments(
        Base.macroexpand(mod, _stable_expression(ctx, definition, line); recursive=false))
    original = _definition(definition)
    original === nothing || (expanded = _restore_doctor_sources(expanded, original, line))
    if !isdefined(mod, :!)
        original === nothing || (expanded = _qualify_doctor_wrapper(expanded,
            _syntax_name(get(original, :name, nothing))))
    end
    return expanded
end

function _doctor_canary!(ctx, mod::Module)
    # DispatchDoctor suppresses checks while generating a precompile image.
    # Do not mark that module checked; the live test process must run the canary.
    ccall(:jl_generating_output, Cint, ()) != 0 && return nothing
    lock(ctx.lock) do
        mod in ctx.checked_modules && return nothing
        _check_preferences(ctx, mod)
        name = gensym(:dispatch_checkup_canary)
        # Any is unstable regardless of a finite-union preference. This runs in
        # the actual target module, so its effective UUID preferences are tested.
        definition = :(function $name(values::$(Vector{Any})); $(first)(values); end)
        Core.eval(mod, _expand_stable(ctx, mod, definition, LineNumberNode(1, Symbol("DispatchCheckup canary"))))
        caught = try
            Base.invokelatest(Base.invokelatest(getglobal, mod, name), Any[1])
            nothing
        catch error
            error
        end
        caught isa DispatchDoctor.TypeInstabilityError || throw(ArgumentError(
            "DispatchDoctor is inactive or incompatible in $mod: the unstable canary did not throw TypeInstabilityError"))
        push!(ctx.checked_modules, mod)
    end
    return nothing
end

function _contains_checker(ex)
    ex === DispatchDoctor.TypeInstabilityError && return true
    ex isa QuoteNode && return _contains_checker(ex.value)
    ex isa GlobalRef && return isdefined(ex.mod, ex.name) && Base.invokelatest(getglobal, ex.mod, ex.name) === DispatchDoctor.TypeInstabilityError
    ex isa Expr && return any(_contains_checker, ex.args)
    return false
end

_unstable_expression(definition, line) = Expr(:macrocall,
    GlobalRef(DispatchDoctor, Symbol("@unstable")), line, definition)

macro _instrumented_definition(config_file, fallback, file, line, definition)
    ctx = _instrumentation_context(config_file)
    name = _generic_name(__module__, definition, fallback)
    if _excluded!(ctx, name, fallback, __module__)
        _record!(ctx, :excluded, name, file, line, "requested unstable exclusion")
        return esc(_unstable_expression(definition, LineNumberNode(line, Symbol(file))))
    end
    def = _definition(definition)
    if def !== nothing && _contains_definition(get(def, :body, nothing))
        _record!(ctx, :unsupported, name, file, line,
            "nested definitions or closures are not independently checked")
    end
    _doctor_canary!(ctx, __module__)
    expanded = _expand_stable(ctx, __module__, definition, LineNumberNode(line, Symbol(file)))
    if _contains_checker(expanded)
        _record!(ctx, :instrumented, name, file, line)
    else
        _record!(ctx, :unsupported, name, file, line, "DispatchDoctor did not instrument this definition")
    end
    return esc(expanded)
end

# Collect visible declarations without expanding opaque macros or executing eval.
# In particular, an @eval block can contain several independently named methods.
function _syntactic_definitions(ex)
    ex isa Expr || return Any[]
    _definition(ex) === nothing || return Any[ex]
    ex.head === :macro && return Any[ex]
    definitions = Any[]
    for arg in ex.args
        append!(definitions, _syntactic_definitions(arg))
    end
    return definitions
end

macro _skipped_definition(config_file, fallback, file, line, reason, definition)
    ctx = _instrumentation_context(config_file)
    definitions = _syntactic_definitions(definition)
    isempty(definitions) && push!(definitions, definition)
    all_excluded = true
    for candidate in definitions
        hint = candidate === definition ? fallback : _definition_hint(candidate, string(__module__))
        name = _generic_name(__module__, candidate, hint)
        excluded = _excluded!(ctx, name, hint, __module__)
        kind = excluded || reason == "source @unstable annotation" ? :excluded : :unsupported
        all_excluded &= kind === :excluded
        _record!(ctx, kind, name, file, line, excluded ? "requested unstable exclusion" : reason)
    end
    result = all_excluded ? _unstable_expression(definition, LineNumberNode(line, Symbol(file))) : definition
    return esc(result)
end

function _register_instrumented_module(config_file, mod::Module)
    ctx = _instrumentation_context(config_file)
    lock(ctx.lock) do
        push!(ctx.modules, mod)
    end
    _doctor_canary!(ctx, mod)
    return nothing
end

const _CONTROL_MACROS = Set((Symbol("@static"), Symbol("@everywhere")))
const _NONDEFINING_MACROS = Set(Symbol.(
    ("@__DIR__", "@__FILE__", "@__MODULE__", "@__LINE__", "@isdefined", "@assert",
     "@info", "@warn", "@error", "@debug", "@show", "@time", "@timed", "@elapsed",
     "@allocated", "@allocations", "@inbounds", "@boundscheck")))
const _KNOWN_SKIPPED_MACROS = Set((Symbol("@generated"), Symbol("@eval"), Symbol("@opaque"),
    Symbol("@assume_effects"), Symbol("@pure"), Symbol("@kwdef"), Symbol("@enum"), Symbol("@deprecate"),
    Symbol("@device_override"), Symbol("@device_function"), Symbol("@device_functions"),
    Symbol("@overlay"), Symbol("@consistent_overlay")))
const _BASE_LITERAL_MACROS = Set(Symbol.(
    ("@v_str", "@r_str", "@s_str", "@b_str", "@raw_str", "@big_str",
     "@int128_str", "@uint128_str", "@MIME_str", "@html_str", "@text_str")))

macro _literal_expression(config_file, file, line, expression)
    ctx = _instrumentation_context(config_file)
    name = _macro_name(expression.args[1])
    expected = Base.invokelatest(getglobal, Base, name)
    if _binding(__module__, expression.args[1]) !== expected
        _record!(ctx, :unsupported, string(__module__) * ".<macro>", file, line,
            "opaque macro $(name) may generate unchecked definitions")
    end
    return esc(expression)
end

macro _jll_expression(config_file, file, line, expression)
    ctx = _instrumentation_context(config_file)
    macro_function = _binding(__module__, expression.args[1])
    if !(macro_function isa Function) ||
       Base.PkgId(parentmodule(macro_function)).uuid != UUID("692b3bcd-3c85-4b1f-b108-f13ce0eb3210")
        _record!(ctx, :unsupported, string(__module__) * ".<macro>", file, line,
            "unrecognized JLL loader macro binding")
        return esc(expression)
    end
    expanded = Base.macroexpand(__module__, expression; recursive=false)
    # The generated loader chooses a platform file at runtime. Map those native
    # includes too; the dependency's own generated helper definitions remain a
    # visible coverage gap, rather than masquerading as handwritten target code.
    _contains_definition(expanded) && _record!(ctx, :unsupported,
        string(__module__) * ".<JLLWrappers>", file, line,
        "JLLWrappers-generated helper definitions are not source-instrumented")
    mapped = _rewrite_calls(ctx, expanded, string(__module__), file, line)
    if _macro_name(expression.args[1]) == Symbol("@generate_main_file_header")
        # JLLWrappers deliberately disables inference for fast ordinary loading.
        # Its private testing overlay needs inference for the inserted checks.
        enable = Expr(:call, GlobalRef(Core, :eval), __module__,
            QuoteNode(:(Base.Experimental.@compiler_options infer=true)))
        mapped = Expr(:block, mapped, enable)
    end
    return esc(mapped)
end

function _check_include_string_value(value, file, line)
    value === Base.include_string && throw(ArgumentError(
        "first-class include_string reference at $file:$line cannot be instrumented safely; " *
        "use a direct Base.include_string(...) call instead of an alias or passed loader"))
    return value
end

function _include_string_value(ex, file, line)
    reference = ex === :include_string || _syntax_name(ex) == "Base.include_string"
    if ex isa Expr && ex.head === :call && length(ex.args) == 3 &&
       _syntax_name(ex.args[1]) in ("getfield", "Core.getfield", "getproperty", "Base.getproperty") &&
       ex.args[2] === :Base && ex.args[3] == QuoteNode(:include_string)
        reference = true
    end
    reference || return nothing
    return Expr(:call, GlobalRef(@__MODULE__, :_check_include_string_value), ex, file, line)
end

function _definition_macro(ctx, macro_name, ex, scope, file, line, reason=nothing; hint=nothing)
    args = Any[GlobalRef(@__MODULE__, macro_name), LineNumberNode(line, Symbol(file)),
               ctx.config_file, hint === nothing ? _definition_hint(ex, scope) : hint, file, line]
    reason === nothing || push!(args, reason)
    push!(args, ex)
    return Expr(:macrocall, args...)
end

function _contains_definition(ex)
    ex isa Expr || return false
    ex.head === :function && length(ex.args) == 1 && return false
    (ex.head in (:function, :->, :macro) || MacroTools.isdef(ex)) && return true
    return any(_contains_definition, ex.args)
end

function _native_include_call(ctx, ex, scope, file, line)
    ex.head == :call || return nothing
    callee = ex.args[1]
    name = _syntax_name(callee)
    (callee === :include || callee === :include_string ||
        name in ("Base.include", "Base.include_string")) || return nothing
    args = map(arg -> _rewrite_calls(ctx, arg, scope, file, line), ex.args[2:end])
    module_expr = Expr(:macrocall, GlobalRef(Base, Symbol("@__MODULE__")), LineNumberNode(line, Symbol(file)))
    helper = if callee === :include
        Expr(:call, GlobalRef(@__MODULE__, :_prepare_bare_include), ctx.config_file, module_expr, :include, args...)
    elseif name == "Base.include"
        Expr(:call, GlobalRef(@__MODULE__, :_prepare_base_include), ctx.config_file, args...)
    elseif name == "Base.include_string" || callee === :include_string
        Expr(:call, GlobalRef(@__MODULE__, :_prepare_include_string), ctx.config_file, args...)
    else
        return nothing
    end
    # Keep the native callee visible to Julia's top-level lowering. The prepared
    # tuple also evaluates each original argument once, in its original order.
    return Expr(:call, callee, Expr(:..., helper))
end

function _rewrite_calls(ctx, ex, scope, file, line)
    if !(ex isa Expr)
        guarded = _include_string_value(ex, file, line)
        return guarded === nothing ? ex : guarded
    end
    ex.head == :quote && return ex
    ex.head in (:import, :using, :export, :public) && return ex
    if ex.head === :function || ex.head === :-> || (ex.head === :(=) && MacroTools.isdef(ex))
        # A declaration's call-shaped signature is not an invocation. Preserve
        # its callee, including methods named include, while mapping defaults.
        signature = _rewrite_signature(ctx, ex.args[1], scope, file, line)
        body = map(arg -> _rewrite_calls(ctx, arg, scope, file, line), ex.args[2:end])
        return Expr(ex.head, signature, body...)
    end
    native = _native_include_call(ctx, ex, scope, file, line)
    native === nothing || return native
    guarded = _include_string_value(ex, file, line)
    guarded === nothing || return guarded
    if ex.head in (:(=), :kw)
        return Expr(ex.head, ex.args[1], _rewrite_calls(ctx, ex.args[2], scope, file, line))
    end
    if ex.head == :call && _syntax_name(ex.args[1]) in ("eval", "Core.eval", "Base.eval")
        _record!(ctx, :unsupported, scope * ".<eval>", file, line, "dynamic eval is not source-instrumented")
    elseif ex.head == :macrocall && _macro_name(ex.args[1]) == Symbol("@eval")
        _record!(ctx, :unsupported, scope * ".<eval>", file, line, "@eval-generated definitions are not source-instrumented")
        return ex
    end
    return Expr(ex.head, map(arg -> _rewrite_calls(ctx, arg, scope, file, line), ex.args)...)
end

function _rewrite_signature(ctx, ex, scope, file, line)
    ex isa Expr || return ex
    if ex.head === :call
        return Expr(:call, ex.args[1],
            map(arg -> _rewrite_argument(ctx, arg, scope, file, line), ex.args[2:end])...)
    elseif ex.head === :where
        parameters = map(ex.args[2:end]) do parameter
            parameter isa Symbol && return parameter
            if parameter isa Expr && parameter.head in (:<:, :>:) && length(parameter.args) == 2
                return Expr(parameter.head, parameter.args[1],
                    _rewrite_calls(ctx, parameter.args[2], scope, file, line))
            end
            return parameter
        end
        return Expr(:where, _rewrite_signature(ctx, ex.args[1], scope, file, line), parameters...)
    elseif ex.head === :(::)
        return Expr(ex.head, _rewrite_signature(ctx, ex.args[1], scope, file, line),
            map(arg -> arg isa Symbol ? arg : _rewrite_calls(ctx, arg, scope, file, line), ex.args[2:end])...)
    end
    return _rewrite_argument(ctx, ex, scope, file, line)
end

function _rewrite_argument(ctx, ex, scope, file, line)
    ex isa Expr || return ex
    if ex.head in (:kw, :(=), :(::)) && length(ex.args) == 2
        value = ex.head === :(::) && ex.args[2] isa Symbol ? ex.args[2] :
            _rewrite_calls(ctx, ex.args[2], scope, file, line)
        return Expr(ex.head, _rewrite_argument(ctx, ex.args[1], scope, file, line),
            value)
    elseif ex.head in (:tuple, :parameters, :...)
        return Expr(ex.head, map(arg -> _rewrite_argument(ctx, arg, scope, file, line), ex.args)...)
    end
    return ex
end

function _transform_expression(ctx, ex, scope, file, line)
    if !(ex isa Expr)
        guarded = _include_string_value(ex, file, line)
        return guarded === nothing ? ex : guarded
    end
    ex.head in (:import, :using, :export, :public) && return ex
    native = _native_include_call(ctx, ex, scope, file, line)
    native === nothing || return native
    guarded = _include_string_value(ex, file, line)
    guarded === nothing || return guarded
    if ex.head == :module
        name = String(ex.args[2])
        child_scope = scope == "<loader>" ? name : scope * "." * name
        body = _transform_expression(ctx, ex.args[3], child_scope, file, line)
        module_expr = Expr(:macrocall, GlobalRef(Base, Symbol("@__MODULE__")), LineNumberNode(line, Symbol(file)))
        push!(body.args, Expr(:call, GlobalRef(@__MODULE__, :_register_instrumented_module), ctx.config_file, module_expr))
        return Expr(:module, ex.args[1], ex.args[2], body)
    elseif ex.head in (:block, :toplevel)
        args = Any[]
        current_line = line
        for arg in ex.args
            arg isa LineNumberNode && (current_line = arg.line)
            push!(args, _transform_expression(ctx, arg, scope, file, current_line))
        end
        return Expr(ex.head, args...)
    elseif ex.head in (:struct, :abstract, :primitive)
        # Type and field names are declarations, not first-class loader values.
        args = copy(ex.args)
        if ex.head === :struct
            body = args[end]
            if body isa Expr && body.head === :block
                args[end] = Expr(:block, map(body.args) do field
                    field isa Symbol && return field
                    field isa Expr && field.head === :(::) && return field
                    _transform_expression(ctx, field, scope, file, line)
                end...)
            end
        end
        return Expr(ex.head, args...)
    elseif ex.head == :quote
        _contains_definition(ex) && _record!(ctx, :unsupported, scope * ".<quote>", file, line,
            "quoted definitions are not source-instrumented")
        return ex
    elseif ex.head == :macro
        return _definition_macro(ctx, Symbol("@_skipped_definition"), ex, scope, file, line,
            "macro definitions are not stabilized by DispatchDoctor")
    elseif ex.head == :macrocall
        name = _macro_name(ex.args[1])
        if ex.args[1] isa GlobalRef && ex.args[1].mod === (@__MODULE__) &&
           name in (Symbol("@_instrumented_definition"), Symbol("@_skipped_definition"), Symbol("@_literal_expression"), Symbol("@_jll_expression"))
            return ex
        elseif name in (Symbol("@generate_main_file_header"), Symbol("@generate_main_file"))
            return Expr(:macrocall, GlobalRef(@__MODULE__, Symbol("@_jll_expression")),
                LineNumberNode(line, Symbol(file)), ctx.config_file, file, line, ex)
        elseif name == Symbol("@doc") && length(ex.args) >= 4
            # Keep documentation attached while mapping the actual declaration,
            # including documented modules whose bodies only contain includes.
            args = copy(ex.args)
            args[end] = _transform_expression(ctx, args[end], scope, file, line)
            return Expr(:macrocall, args...)
        elseif name in _BASE_LITERAL_MACROS && all(arg -> arg isa String, ex.args[3:end])
            # Check the actual binding after preceding imports/definitions ran.
            # A user macro with the same spelling is not trusted. Interpolating
            # lazy strings are deliberately absent: they can contain Julia code.
            return Expr(:macrocall, GlobalRef(@__MODULE__, Symbol("@_literal_expression")),
                LineNumberNode(line, Symbol(file)), ctx.config_file, file, line, ex)
        elseif name == Symbol("@unstable")
            return _definition_macro(ctx, Symbol("@_skipped_definition"),
                _rewrite_calls(ctx, ex, scope, file, line), scope, file, line, "source @unstable annotation")
        elseif name == Symbol("@stable")
            if _definition(ex) !== nothing
                # Replace the existing annotation rather than nesting a second
                # check around it; the activated harness owns effective options.
                definition = _rewrite_calls(ctx, last(ex.args), scope, file, line)
                return _definition_macro(ctx, Symbol("@_instrumented_definition"), definition, scope, file, line)
            end
            _record!(ctx, :unsupported, _definition_hint(ex, scope), file, line,
                "existing @stable block retained without double annotation")
            return ex
        elseif name in _CONTROL_MACROS
            # Retain conditional/distributed staging around the transformed code.
            # Inactive @static branches never expand their definition markers.
            args = copy(ex.args)
            args[end] = _transform_expression(ctx, args[end], scope, file, line)
            return Expr(:macrocall, args...)
        elseif name in _KNOWN_SKIPPED_MACROS
            return _definition_macro(ctx, Symbol("@_skipped_definition"), ex, scope, file, line,
                "macro $(name) is not safely instrumented")
        elseif _definition(ex) !== nothing
            # Let the public @stable macro apply its registered decorator policy
            # in the actual module after preceding imports/registrations ran.
            rewritten = _rewrite_calls(ctx, ex, scope, file, line)
            return _definition_macro(ctx, Symbol("@_instrumented_definition"), rewritten, scope, file, line)
        elseif _contains_definition(ex)
            return _definition_macro(ctx, Symbol("@_skipped_definition"), ex, scope, file, line,
                "macro $(name) is not safely instrumented")
        end
        if !(name in _NONDEFINING_MACROS)
            _record!(ctx, :unsupported, scope * ".<macro>", file, line,
                "opaque macro $(name) may generate unchecked definitions")
        end
        return _rewrite_calls(ctx, ex, scope, file, line)
    elseif ex.head === :function && length(ex.args) == 1
        # Declaring an empty generic introduces no method body to stabilize.
        return ex
    elseif MacroTools.isdef(ex)
        # Nested definitions/closures are a documented DispatchDoctor limitation;
        # retain native behavior and make those gaps visible in the report.
        def = _definition(ex)
        if def === nothing
            return _definition_macro(ctx, Symbol("@_skipped_definition"), ex, scope, file, line,
                "unsupported function syntax")
        end
        rewritten = _rewrite_calls(ctx, ex, scope, file, line)
        return _definition_macro(ctx, Symbol("@_instrumented_definition"), rewritten, scope, file, line)
    elseif ex.head in (:(=), :kw)
        binding = ex.args[1]
        binding isa Expr && binding.head === :(::) && (binding = binding.args[1])
        if ex.head === :(=) && binding isa Symbol && _definition(ex.args[2]) !== nothing
            definition = _rewrite_calls(ctx, ex.args[2], scope, file, line)
            marked = _definition_macro(ctx, Symbol("@_instrumented_definition"),
                definition, scope, file, line; hint=scope * "." * String(binding))
            return Expr(:(=), ex.args[1], marked)
        end
        return Expr(ex.head, ex.args[1], _transform_expression(ctx, ex.args[2], scope, file, line))
    elseif ex.head in (:global, :local)
        return Expr(ex.head, map(ex.args) do arg
            arg isa Symbol ? arg : _transform_expression(ctx, arg, scope, file, line)
        end...)
    end
    args = Any[]
    current_line = line
    for arg in ex.args
        arg isa LineNumberNode && (current_line = arg.line)
        push!(args, _transform_expression(ctx, arg, scope, file, current_line))
    end
    return Expr(ex.head, args...)
end

function _expression_line(ex, fallback::Int=1)
    ex isa LineNumberNode && return ex.line
    ex isa Expr || return fallback
    for arg in ex.args
        line = _expression_line(arg, 0)
        line == 0 || return line
    end
    return fallback
end

function _include_mapper(ctx, mod::Module, original_mapper::Function; filename=nothing)
    ex -> begin
        file = filename === nothing ? _original_path(ctx, Base.source_path()) : String(filename)
        mapped = Base.invokelatest(original_mapper, _source_lines(ctx, ex))
        mapped = _source_lines(ctx, mapped)
        line = _expression_line(mapped, _expression_line(ex))
        lock(ctx.lock) do
            push!(ctx.files, file)
        end
        scope = mod === Base.__toplevel__ ? "<loader>" : string(mod)
        _transform_expression(ctx, mapped, scope, file, line)
    end
end

function _prepare_bare_include(config_file, mod::Module, callee, path::AbstractString)
    callee isa Base.IncludeInto || throw(ArgumentError("custom include binding cannot be instrumented safely"))
    ctx = _instrumentation_context(config_file)
    return (_include_mapper(ctx, mod, identity), _expect_include!(ctx, mod, _snapshot_path(ctx, path)))
end
function _prepare_bare_include(config_file, mod::Module, callee, mapper::Function, path::AbstractString)
    callee isa Base.IncludeInto || throw(ArgumentError("custom include binding cannot be instrumented safely"))
    ctx = _instrumentation_context(config_file)
    return (_include_mapper(ctx, mod, mapper), _expect_include!(ctx, mod, _snapshot_path(ctx, path)))
end
function _prepare_base_include(config_file, mod::Module, path::AbstractString)
    ctx = _instrumentation_context(config_file)
    return (_include_mapper(ctx, mod, identity), mod, _expect_include!(ctx, mod, _snapshot_path(ctx, path)))
end
function _prepare_base_include(config_file, mapper::Function, mod::Module, path::AbstractString)
    ctx = _instrumentation_context(config_file)
    return (_include_mapper(ctx, mod, mapper), mod, _expect_include!(ctx, mod, _snapshot_path(ctx, path)))
end
function _prepare_include_string(config_file, mod::Module, code::AbstractString, filename::AbstractString="string")
    ctx = _instrumentation_context(config_file)
    return (_include_mapper(ctx, mod, identity; filename), mod, code, filename)
end
function _prepare_include_string(config_file, mapper::Function, mod::Module, code::AbstractString, filename::AbstractString="string")
    ctx = _instrumentation_context(config_file)
    return (_include_mapper(ctx, mod, mapper; filename), mod, code, filename)
end

function instrument_entry(loader_mod::Module, config_file::AbstractString, original_entry::AbstractString)
    ctx = _instrumentation_context(config_file)
    original_entry = _original_path(ctx, original_entry)
    snapshot = _snapshot_path(ctx, original_entry)
    lock(ctx.lock) do
        push!(ctx.entries, original_entry)
    end
    return Base.include(_include_mapper(ctx, loader_mod, identity), loader_mod,
        _expect_include!(ctx, loader_mod, snapshot))
end

function validate_exclusions!(config_file::AbstractString)
    ctx = _instrumentation_context(config_file)
    unmatched = sort!([name for (name, matches) in ctx.exclusions if matches == 0])
    isempty(unmatched) || throw(ArgumentError("unmatched unstable exclusions: " * join(unmatched, ", ")))
    return nothing
end

function _validate_coverage_policy!(ctx)
    if ctx.require_all
        unsupported = filter(record -> record.kind === :unsupported, ctx.records)
        isempty(unsupported) || throw(ArgumentError("unsupported definitions remain under require_all=true: " *
            join(unique(record.reason for record in unsupported), "; ")))
    end
    return nothing
end

function validate_instrumentation!(config_file::AbstractString)
    key = abspath(config_file)
    haskey(_INSTRUMENTATION_CONTEXTS, key) || throw(ArgumentError("instrumentation entry shim never ran"))
    ctx = _instrumentation_context(key)
    _validate_include_observations!(ctx)
    ctx.main_entry in ctx.entries || throw(ArgumentError("the main package entry was not instrumented"))
    roots = filter(mod -> string(mod) == ctx.target, collect(ctx.modules))
    length(roots) == 1 || throw(ArgumentError("expected exactly one instrumented target module $(ctx.target)"))
    Base.PkgId(only(roots)).uuid == ctx.target_uuid || throw(ArgumentError("instrumented package UUID changed"))
    for mod in ctx.modules
        _doctor_canary!(ctx, mod)
    end
    _validate_coverage_policy!(ctx)
    return nothing
end

function instrumentation_report(config_file::AbstractString)
    ctx = _instrumentation_context(config_file)
    records = [Dict("kind"=>String(record.kind), "name"=>record.name, "file"=>record.file,
                    "line"=>record.line, "reason"=>record.reason) for record in ctx.records]
    counts = Dict(String(kind)=>count(record -> record.kind === kind, ctx.records)
                  for kind in (:instrumented, :excluded, :unsupported))
    return Dict("target"=>ctx.target, "uuid"=>string(ctx.target_uuid),
                "files"=>sort!(collect(ctx.files)), "entries"=>sort!(collect(ctx.entries)),
                "modules"=>sort!(string.(collect(ctx.modules))), "counts"=>counts,
                "exclusions"=>copy(ctx.exclusions), "records"=>records,
                "observed_includes"=>[Dict("module"=>event.scope,"file"=>event.path,
                    "instrumented"=>event.instrumented) for event in ctx.observed_includes])
end

function original_source_root(mod::Module)
    lock(_INSTRUMENTATION_LOCK) do
        for ctx in values(_INSTRUMENTATION_CONTEXTS)
            _owned_module(ctx, mod) && return ctx.original_root
        end
        return pkgdir(mod)
    end
end

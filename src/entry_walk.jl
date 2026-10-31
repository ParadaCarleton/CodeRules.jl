# The frames an entry point compiles, found by walking optimized IR along `:invoke` edges.
# `inferred_methods` needs them as its signatures; a dispatch audit reads the same IR.

"""
    mentions_module(signature, target, depth)

Whether `signature` names a type defined in `target` anywhere in its parameters.
"""
function mentions_module(signature::Any, target::Module, depth::Integer)::Bool
    if depth > 6
        return false
    elseif signature isa UnionAll
        return mentions_module(signature.body, target, depth + 1)
    elseif signature isa Union
        return mentions_module(signature.a, target, depth + 1) ||
            mentions_module(signature.b, target, depth + 1)
    elseif !(signature isa DataType)
        return false
    end
    return parentmodule(signature) === target ||
        any(parameter -> mentions_module(parameter, target, depth + 1), signature.parameters)
end

"""
    builtin_callee(called)

Whether a `:call` statement's callee is a builtin or an intrinsic, which keep the `:call` head after
optimization without dispatching. They appear inline or as a `GlobalRef`.
"""
builtin_callee(called::Any)::Bool = called isa Core.Builtin || called isa Core.IntrinsicFunction
builtin_callee(called::GlobalRef)::Bool =
    isdefined(called.mod, called.name) && builtin_callee(getglobal(called.mod, called.name))

"""
    invoked_instance(callee)

The method instance an `:invoke` statement names: a `CodeInstance` on Julia 1.12 and later.
"""
invoked_instance(callee::Core.MethodInstance)::Core.MethodInstance = callee
invoked_instance(callee::Core.CodeInstance)::Union{Nothing, Core.MethodInstance} = invoked_instance(callee.def)
invoked_instance(::Any)::Nothing = nothing

"""
    logging_call(statement)

Whether a `:call` statement is a logging macro's hand-off to the current logger, which is an
`AbstractLogger` chosen at runtime and so always dispatches.
"""
logging_call(statement::Expr)::Bool = any(
    argument -> argument isa GlobalRef && argument.mod === Base.CoreLogging || argument === Base.CoreLogging.handle_message,
    statement.args,
)

"""
    frame_callees(code, target)

The signatures `code`, an optimized method body, calls through `:invoke` edges and a walk of `target`
follows: callees defined in `target` or whose signature names one of its types (JET's `target_modules`
scope).
"""
function frame_callees(code::Core.CodeInfo, target::Module)::Vector{Type}
    expressions = [statement for statement in code.code if statement isa Expr]
    invoked = [invoked_instance(first(statement.args)) for statement in expressions if statement.head in (:invoke, :invoke_modify)]
    return Type[
        callee.specTypes for callee in invoked
            if callee isa Core.MethodInstance && callee.def isa Method &&
            (callee.def.module === target || mentions_module(callee.specTypes, target, 0))
    ]
end

"""
    entry_frames(seeds, target)

The optimized frames (`code_typed_by_type` results, empty when inference yields none) of every signature
reachable from `seeds` (entry-point call signatures such as `Tuple{typeof(f), Int}`) along
`frame_callees` edges, the seeds included. A caller that audits the frames reads them from here and
infers nothing twice.
"""
function entry_frames(seeds::AbstractVector{<:Type}, target::Module)::Dict{Type, Vector{Pair{Core.CodeInfo, Any}}}
    frames = Dict{Type, Vector{Pair{Core.CodeInfo, Any}}}()
    frontier = unique(Type[seeds...])
    while !isempty(frontier)
        for signature in frontier
            frames[signature] = Pair{Core.CodeInfo, Any}[Base.code_typed_by_type(signature; optimize = true)...]
        end
        frontier = new_callees(frames, frontier, target)
    end
    return frames
end

"""The signatures the `frontier` frames call that `frames` does not hold yet."""
new_callees(frames::AbstractDict{Type}, frontier::AbstractVector{<:Type}, target::Module)::Vector{Type} = unique(
    Type[
        callee for signature in frontier for (code, _) in frames[signature]
            for callee in frame_callees(code, target) if !haskey(frames, callee)
    ],
)

"""
    entry_signatures(seeds, target)

The signatures of `entry_frames(seeds, target)`. Pass them to `inferred_methods`: they name the frames
the entry points compile, whatever the session ran before.
"""
entry_signatures(seeds::AbstractVector{<:Type}, target::Module)::Vector{Type} = collect(keys(entry_frames(seeds, target)))

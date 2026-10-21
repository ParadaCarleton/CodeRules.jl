# Counts Float64 operations in a call's fully optimized IR, a check for widening that a wrapper
# number type (StrictFloat32) cannot see. See `float64_ops`.
using InteractiveUtils: code_llvm

const FLOAT64_IR_OPS =
    ("fadd", "fmul", "fsub", "fdiv", "frem", "fcmp", "fpext", "fptrunc", "call")

"""
    float64_ops(f, types)

Number of Float64 operations in the fully optimized IR of `f(::types...)`.

A wrapper type observes a Float64 only when it is promoted with, or converted from,
one of ours, so a dependency that computes internally at Float64 and narrows before
returning is invisible to Strict32 — the expensive silent case, where the caller pays
Float64 arithmetic and keeps Float32 storage. The IR sees that widening whichever
package caused it, without forking or instrumenting the dependency.

Heuristic, not a proof: it reads the IR `optimize=true` produced for one concrete
signature, so a Float64 reached only through runtime dispatch is out of scope, and a
non-inlined callee is visible through its call signature rather than its body. Use
`== 0` on kernels that must stay narrow, and keep the positive controls so a change
to the filter cannot quietly disarm the check.
"""
function float64_ops(f::Any, types::Tuple)::Int
    buffer = IOBuffer()
    code_llvm(buffer, f, types; optimize = true, debuginfo = :none)
    return count(split(String(take!(buffer)), '\n')) do line
        occursin("double", line) && any(op -> occursin(op, line), FLOAT64_IR_OPS)
    end
end

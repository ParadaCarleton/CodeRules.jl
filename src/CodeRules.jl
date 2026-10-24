"""
Code-quality rules checked on a loaded module and on its repository's Julia source. A rule finds
`Site`s; `ratchet!` holds them to the per-rule counts in the `Repository`'s baseline file, failing a
test on new offenders and lowering the counts when offenders go away. The caller picks the rules
(each is a function returning sites), the module and source files they read, and their limits.
"""
module CodeRules

export Repository, Site, ratchet!, @call_sites, @opt_sites, float64_ops

include("ratchet.jl")
include("rules.jl")
include("jet.jl")
include("float64_scan.jl")
include("imports.jl")
include("where_return.jl")

end

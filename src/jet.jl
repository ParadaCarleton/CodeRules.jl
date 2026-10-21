# JET reports as ratchet sites: each report is one site, keyed by the scope (the testset's
# analysis), the function it was found in and the report's kind, and placed at the source line of
# the frame where JET raised it, so the `jet` rule's opt-out comment on that line takes it out.

using JET: JET

"""The `Site` of JET report `report`: its innermost frame names the function and the line."""
function jet_site(scope::String, report::JET.InferenceErrorReport)::Site
    frame = last(report.vst)
    method = frame.linfo.def
    name = method isa Method ? method.name : :top_level
    return Site("$scope: $name $(nameof(typeof(report)))", string(frame.file), frame.line)
end

"""One site per report of JET analysis `result`."""
jet_sites(scope::String, result::JET.JETCallResult)::Vector{Site} = [jet_site(scope, report) for report in JET.get_reports(result)]

"""The code of `@call_sites` and `@opt_sites`: `sites` gains the sites of `report_macro` run on `arguments`."""
function jet_assertion(report_macro::Symbol, scope::String, source::LineNumberNode, sites::Symbol, arguments::Tuple)::Expr
    analysis = esc(Expr(:macrocall, GlobalRef(JET, report_macro), source, arguments...))
    return :(append!($(esc(sites)), jet_sites($scope, $analysis)))
end

"""`@call_sites scope sites target_modules = (…,) call(…)`: `JET.@report_call`'s reports appended to the vector `sites`."""
macro call_sites(scope, sites, arguments...)
    return jet_assertion(Symbol("@report_call"), scope, __source__, sites, arguments)
end

"""`@opt_sites scope sites target_modules = (…,) call(…)`: `JET.@report_opt`'s reports appended to the vector `sites`."""
macro opt_sites(scope, sites, arguments...)
    return jet_assertion(Symbol("@report_opt"), scope, __source__, sites, arguments)
end

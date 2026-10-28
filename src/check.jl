# Runs the registered rules over a project and judges their sites against the baseline.

"""One site a rule found, with the level it was found at."""
struct Finding
    rule::String
    level::Symbol
    site::Site
end

"""The allowances the baseline file of `repository` holds for `rule`: none when there is no file or no table."""
function allowances(repository::Repository, rule::AbstractString)::Dict{String, Any}
    if isnothing(repository.baseline) || !isfile(repository.baseline)
        return Dict{String, Any}()
    end
    return get(TOML.parsefile(repository.baseline), rule, Dict{String, Any}())
end

"""
The findings among `sites` of `rule` at `level`: the sites no `# lint:` comment opts out, whose key the
baseline does not allow. With `update`, the baseline is seeded and lowered as `offenders!` does.
"""
function judge(repository::Repository, rule::Rule, level::Symbol, sites::AbstractVector{Site}, update::Bool)::Vector{Finding}
    name = rule_name(rule)
    over = String[]
    if update
        if !isnothing(repository.baseline) && !isfile(repository.baseline)
            touch(repository.baseline)
        end
        over = offenders!(repository, name, sites)
    else
        kept, _ = unopted(sites, name)
        over = exceeding(allowances(repository, name), tally(kept))
    end
    return [Finding(name, level, site) for site in first(unopted(sites, name)) if site.key in over]
end

"""The names of the rules in `rules` that read the loaded package."""
module_rule_names(rules::Tuple)::Vector{String} = [rule_name(rule) for rule in rules if rule isa ModuleRule]

"""The rules `config` leaves on."""
enabled_rules(config::Config)::Tuple = Tuple(rule for rule in RULES if level(config, rule) !== :allow)

"""
    run_rules(config, root; mod = nothing, fix = false, update_baseline = false)

The findings of every rule `config` leaves on, over the project at `root`, and the names of the rules
skipped because they read the loaded package `mod` and none was given. `fix` first rewrites the files
for the rules that have a fixer. `update_baseline` seeds and lowers the baseline file; without it the
baseline is only read.
"""
function run_rules(
        config::Config, root::AbstractString; mod::Union{Module, Nothing} = nothing, fix::Bool = false, update_baseline::Bool = false,
    )::Tuple{Vector{Finding}, Vector{String}}
    repository_ = repository(config, root)
    directories = present_directories(repository_, config.directories)
    enabled = enabled_rules(config)
    runnable = Tuple(rule for rule in enabled if !(rule isa ModuleRule) || !isnothing(mod))
    skipped = setdiff(module_rule_names(enabled), module_rule_names(runnable))
    if fix
        for rule in runnable
            if fixable(rule)
                fix!(rule, Context(repository_, directories, mod, Inferred[]))
            end
        end
    end
    needs_inferred = any(rule -> rule isa AbstractLocalRule || rule isa BangRule, runnable)
    inferred = Inferred[]
    if needs_inferred
        inferred = inferred_methods(mod)
    end
    context = Context(repository_, directories, mod, inferred)
    sites = Dict{String, Vector{Site}}(rule_name(rule) => Site[] for rule in runnable)
    for rule in runnable
        if !(rule isa FileRule)
            append!(sites[rule_name(rule)], check(rule, context))
        end
    end
    file_rules = Tuple(rule for rule in runnable if rule isa FileRule)
    if !isempty(file_rules)
        for path in repository_sources(repository_, directories)
            located = located_source(path)
            for rule in file_rules
                append!(sites[rule_name(rule)], check(rule, context, path, located))
            end
        end
    end
    findings = Finding[]
    for rule in runnable
        append!(findings, judge(repository_, rule, level(config, rule), sites[rule_name(rule)], update_baseline))
    end
    return sort!(findings; by = finding -> (finding.site.file, finding.site.line, finding.rule)), skipped
end

# Per-project settings for the `corset` command, read from the `[preferences.Corset]` table of the
# project's Project.toml and the `[Corset]` table of its LocalPreferences.toml (which wins per key).

"""
    Config

What a project sets for `corset`: the source `directories` to read, the `baseline` file, the
`Repository` exemptions, whether the `pedantic` group is on, and per-rule `levels` (`:allow`,
`:warn` or `:deny`) that override a rule's group.
"""
struct Config
    directories::Tuple{Vararg{String}}
    baseline::Union{String, Nothing}
    one_letter_exempt::Tuple{Vararg{Symbol}}
    skipped_directories::Tuple{Vararg{String}}
    pedantic::Bool
    levels::Dict{String, Symbol}
end

const LEVELS = (:allow, :warn, :deny)
const CONFIG_KEYS = ("directories", "baseline", "one_letter_exempt", "skipped_directories", "pedantic", "levels")

"""The `[Corset]` preferences of `root`: Project.toml's table overlaid by LocalPreferences.toml's, key by key."""
function preference_table(root::AbstractString)::Dict{String, Any}
    table = Dict{String, Any}()
    project = joinpath(root, "Project.toml")
    if isfile(project)
        merge!(table, get(get(TOML.parsefile(project), "preferences", Dict{String, Any}()), "Corset", Dict{String, Any}()))
    end
    local_file = joinpath(root, "LocalPreferences.toml")
    if isfile(local_file)
        merge!(table, get(TOML.parsefile(local_file), "Corset", Dict{String, Any}()))
    end
    return table
end

"""
    load_config(root)

The `Config` of the project at `root`. An unknown key, an unknown rule name or a level other than
`allow`, `warn` or `deny` throws, so a typo cannot silently switch a rule off.
"""
function load_config(root::AbstractString)::Config
    table = preference_table(root)
    unknown = setdiff(keys(table), CONFIG_KEYS)
    if !isempty(unknown)
        error("unknown [preferences.Corset] key(s) $(sort!(collect(unknown))); known keys are $(join(CONFIG_KEYS, ", "))")
    end
    levels = Dict{String, Symbol}(rule => Symbol(level) for (rule, level) in get(table, "levels", Dict{String, Any}()))
    for (rule, level) in levels
        if rule ∉ rule_name.(RULES)
            error("[preferences.Corset.levels] names no rule $(repr(rule)); the rules are $(join(rule_name.(RULES), ", "))")
        end
        if level ∉ LEVELS
            error("[preferences.Corset.levels] sets $rule to $(repr(string(level))); a level is one of $(join(LEVELS, ", "))")
        end
    end
    return Config(
        Tuple(String.(get(table, "directories", ["src"]))),
        get(table, "baseline", nothing),
        Tuple(Symbol.(get(table, "one_letter_exempt", String[]))),
        Tuple(String.(get(table, "skipped_directories", String[]))),
        get(table, "pedantic", false),
        levels,
    )
end

"""The `Repository` for `config` rooted at `root`; a relative baseline path is taken from `root`."""
function repository(config::Config, root::AbstractString)::Repository
    baseline = nothing
    if !isnothing(config.baseline)
        baseline = abspath(root, config.baseline)
    end
    return Repository(root; baseline, one_letter_exempt = config.one_letter_exempt, skipped_directories = config.skipped_directories)
end

"""The level `config` gives `rule`: its own setting, else `:warn` for the default group and for the pedantic group when on."""
function level(config::Config, rule::Rule)::Symbol
    if haskey(config.levels, rule_name(rule))
        return config.levels[rule_name(rule)]
    end
    return ifelse(rule_group(rule) === :default || config.pedantic, :warn, :allow)
end

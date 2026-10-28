# The `corset` command: parse arguments, run the rules over a project, print findings, set the exit code.
# A rule that reads the loaded package needs the project's own environment, so the command replaces
# itself with a Julia process running there (`execv`, so no launcher stays resident).

# JSON loads on first use of `--format json`, so the other formats do not pay for it.
using ArgParse: ArgParseSettings, add_arg_table!, parse_args

const INNER_VARIABLE = "CORSET_INNER"

"""Add the argument or option `name` to `settings` with the ArgParse `options` (`help`, `action`, `default`, ...)."""
option!(settings::ArgParseSettings, name::AbstractString; options...)::Nothing = (
    add_arg_table!(settings, name, Dict{Symbol, Any}(options));
    nothing
)

"""The command's argument table."""
function argument_settings()::ArgParseSettings
    settings = ArgParseSettings(;
        prog = "corset",
        description = "Code-quality rules for Julia packages.",
        add_version = true,
        version = string(pkgversion(@__MODULE__)),
    )
    option!(settings, "check"; help = "run the rules over a project", action = :command)
    option!(
        settings,
        "rules";
        help = "list the rules, their groups and their levels",
        action = :command,
    )
    for command in ("check", "rules")
        option!(
            settings[command],
            "path";
            help = "a directory inside the project",
            default = ".",
        )
        option!(
            settings[command],
            "--pedantic";
            help = "turn on the pedantic group",
            action = :store_true,
        )
    end
    check = settings["check"]
    option!(
        check,
        "--format";
        help = "output format: human, concise or json",
        default = "human",
        range_tester = in(("human", "concise", "json")),
    )
    option!(
        check,
        "--fix";
        help = "rewrite files for the rules that have a fixer",
        action = :store_true,
    )
    option!(
        check,
        "--diff";
        help = "print the changes --fix would make, write nothing, and exit 1 if there are any",
        action = :store_true,
    )
    option!(
        check,
        "--deny-warnings";
        help = "exit nonzero on warnings, not only on deny-level findings",
        action = :store_true,
    )
    option!(
        check,
        "--update-baseline";
        help = "seed and lower the baseline file",
        action = :store_true,
    )
    option!(
        check,
        "--no-load";
        help = "do not load the package; skip the rules that read it",
        action = :store_true,
    )
    option!(check, "--allow"; help = "turn a rule off (repeatable)", action = :append_arg)
    option!(check, "--warn"; help = "set a rule to warn (repeatable)", action = :append_arg)
    option!(check, "--deny"; help = "set a rule to deny (repeatable)", action = :append_arg)
    return settings
end

"""The directory of the project that contains `path`."""
function project_root(path::AbstractString)::String
    project = Base.current_project(abspath(path))
    if isnothing(project)
        error("no Project.toml found at or above $(abspath(path))")
    end
    return dirname(project)
end

"""`config` with the pedantic group switched on when `pedantic` is set and the levels in `overrides` (rule => level) applied."""
function with_overrides(
        config::Config,
        pedantic::Bool,
        overrides::AbstractVector{<:Pair{String, Symbol}},
    )::Config
    levels = merge(config.levels, Dict(overrides))
    unknown = setdiff(keys(levels), rule_name.(RULES))
    if !isempty(unknown)
        error(
            "no such rule: $(join(sort!(collect(unknown)), ", ")); `corset rules` lists them",
        )
    end
    return Config(
        config.directories,
        config.baseline,
        config.one_letter_exempt,
        config.skipped_directories,
        config.pedantic || pedantic,
        levels,
    )
end

"""The `rule => level` pairs the `--allow`, `--warn` and `--deny` options of parsed `arguments` name."""
function level_overrides(arguments::AbstractDict)::Vector{Pair{String, Symbol}}
    return [
        rule => Symbol(name)
            for name in ("allow", "warn", "deny")
            for rule in something(arguments[name], String[])
    ]
end

"""Whether any rule `config` leaves on reads the loaded package."""
reads_package(config::Config)::Bool = any(
    rule -> rule isa ModuleRule,
    enabled_rules(config),
)

"""The package at `root`, loaded in the running process."""
function load_package(root::AbstractString)::Module
    name = get(TOML.parsefile(joinpath(root, "Project.toml")), "name", nothing)
    if isnothing(name)
        error(
            "$root/Project.toml names no package; run with --no-load to skip the rules that read one",
        )
    end
    return Base.require(Main, Symbol(name))
end

"""
    relaunch(root, args)

Replace this process with a Julia process whose active project is `root`, running `corset` on `args`.
Corset's own environment stays on the load path after the project's, so the project's versions of shared
dependencies win. Where `execv` does not exist the command runs as a child and its exit code is returned.
"""
function relaunch(root::AbstractString, args::AbstractVector{<:AbstractString})::Cint
    ENV[INNER_VARIABLE] = "1"
    ENV["JULIA_LOAD_PATH"] = join(
        ["@", dirname(Base.active_project()), "@stdlib"],
        ifelse(Sys.iswindows(), ";", ":"),
    )
    command = `$(Base.julia_cmd()) --startup-file=no --project=$root -e "using Corset; exit(Corset.main(ARGS))" -- $args`
    if Sys.iswindows()
        return Cint(run(ignorestatus(command)).exitcode)
    end
    strings = collect(command.exec)
    GC.@preserve strings begin
        argv = Ptr{UInt8}[pointer.(strings); C_NULL]
        ccall(:execv, Cint, (Cstring, Ptr{Ptr{UInt8}}), strings[1], argv)
    end
    error("execv failed: $(Libc.strerror(Libc.errno()))")
end

"""The path of `site` relative to `root`; empty for a site with no file."""
function display_path(root::AbstractString, site::Site)::String
    if isempty(site.file)
        return ""
    end
    return relpath(site.file, root)
end

"""Print `findings` to `io` in `format` (human, concise or json)."""
function print_findings(
        io::IO,
        root::AbstractString,
        findings::AbstractVector{Finding},
        format::AbstractString,
    )::Nothing
    if format == "json"
        records = [
            (;
                rule = finding.rule, level = finding.level, key = finding.site.key, file = display_path(
                    root,
                    finding.site,
                ), line = finding.site.line,
            )
                for finding in findings
        ]
        json = Base.require(@__MODULE__, :JSON)
        println(io, Base.invokelatest(json.json, records))
        return nothing
    end
    for finding in findings
        place = display_path(root, finding.site)
        if format == "concise"
            println(
                io,
                "$place:$(finding.site.line): $(finding.level): [$(finding.rule)] $(finding.site.key)",
            )
        else
            println(io, "$(finding.level)[$(finding.rule)]: $(finding.site.key)")
            if !isempty(place)
                println(io, "  --> $place:$(finding.site.line)")
            end
        end
    end
    return nothing
end

"""The exit code for `findings`: 1 for any deny-level finding, or any finding when `deny_warnings`; else 0."""
function exit_code(findings::AbstractVector{Finding}, deny_warnings::Bool)::Cint
    return Cint(any(finding -> finding.level === :deny || deny_warnings, findings))
end

"""`corset rules`: one line per rule with its group and the level `config` gives it."""
function print_rules(io::IO, config::Config)::Nothing
    for rule in RULES
        println(
            io,
            rpad(rule_name(rule), 20),
            rpad(rule_group(rule), 10),
            rpad(level(config, rule), 7),
            rule_summary(rule),
        )
    end
    return nothing
end

"""`corset check --diff`: print the changes `--fix` would make to `io`; the exit code is 1 when there are any."""
function print_fix_diff(io::IO, config::Config, root::AbstractString, fix::Bool)::Cint
    if fix
        error("--diff writes nothing and --fix writes the changes; pass one")
    end
    changes = fix_diff(config, root)
    print(io, changes)
    return Cint(!isempty(changes))
end

"""Run `corset check` for parsed `arguments` (from the command line `args`); returns the exit code."""
function run_check(arguments::AbstractDict, args::AbstractVector{<:AbstractString})::Cint
    root = project_root(arguments["path"])
    config = with_overrides(
        load_config(root),
        arguments["pedantic"],
        level_overrides(arguments),
    )
    if arguments["diff"]
        return print_fix_diff(stdout, config, root, arguments["fix"])
    end
    loads = reads_package(config) && !arguments["no-load"]
    if loads && !haskey(ENV, INNER_VARIABLE)
        return relaunch(root, args)
    end
    mod = nothing
    if loads
        mod = load_package(root)
    end
    findings, skipped = run_rules(
        config,
        root;
        mod,
        fix = arguments["fix"],
        update_baseline = arguments["update-baseline"],
    )
    print_findings(stdout, root, findings, arguments["format"])
    if !isempty(skipped)
        println(stderr, "skipped (they read the loaded package): ", join(skipped, ", "))
    end
    return exit_code(findings, arguments["deny-warnings"])
end

"""Whether `error_` is a write to a closed pipe (`corset rules | head`), which ends the run quietly."""
broken_pipe(error_::Any)::Bool = error_ isa Base.IOError && error_.code == Base.UV_EPIPE

"""
    main(args)

The `corset` command. Returns the exit code: 0 when clean, 1 when a finding fails the run, 2 on a usage or
configuration error.
"""
function (@main)(args::AbstractVector{<:AbstractString})::Cint
    try
        parsed = parse_args(collect(String, args), argument_settings())
        command = parsed["%COMMAND%"]
        if command == "rules"
            arguments = parsed["rules"]
            config = with_overrides(
                load_config(project_root(arguments["path"])),
                arguments["pedantic"],
                Pair{String, Symbol}[],
            )
            print_rules(stdout, config)
            return Cint(0)
        end
        return run_check(parsed["check"], args)
    catch error_
        if broken_pipe(error_)
            return Cint(0)
        end
        if error_ isa ErrorException
            println(stderr, "corset: ", error_.msg)
            return Cint(2)
        end
        rethrow()
    end
end

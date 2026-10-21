# The ratchet every code-quality rule reports through. A rule hands `ratchet!` the sites it found;
# the repository's baseline file fails a site it does not hold and falls when a run finds fewer.

using Test: @test
using TOML: TOML

# The baseline file holds one table per rule, named as in the rule's opt-out comment. A string
# is a named offender's note ("unassigned" waits on a decision, "kept: …" is deliberate) and
# allows it at any number of sites; an integer allows that many sites. `TOML.print` drops comments.

"""
The tree the rules read and where they keep their counts: `root` is the absolute path of the tree
whose source the rules read, `baseline` the TOML file of per-rule allowances, and
`one_letter_exempt` the variable names the one-letter rule allows besides `_` (a project's own
convention, such as an argument everywhere named `p`). `baseline` may be a link: `ratchet!` resolves
it at each call, so a lowering lands in the file it points to, even in a worker that lives across jobs.
"""
struct Repository
    root::String
    baseline::String
    one_letter_exempt::Tuple{Vararg{Symbol}}
end

"""
One offender a rule found: `key` names it in the baseline; `file` (a path, empty when the offender
has none) and the lines `line` through `last_line` place it for the opt-out comments, so a comment on
any of them takes the site out. Line 0 places it in the file as a whole.
"""
struct Site
    key::String
    file::String
    line::Int
    last_line::Int
end
Site(key::String, file::String, line::Integer) = Site(key, file, line, line)

"""
`# lint: RULE` opts its own line out of `RULE`, `# lint: RULE-begin` … `# lint: RULE-end` the lines
between (inclusive), `# lint: RULE-file` the whole file; the reason follows on the comment. A rule
name is lowercase words joined by `-`.
"""
const OPT_OUT = r"#\s*lint:\s*([a-z0-9]+(?:-[a-z0-9]+)*?)(?:-(file|begin|end))?(?![\w-])"

"""Which lines of one file a rule skips: all of them when `whole_file`, else `lines`."""
struct OptOuts
    whole_file::Bool
    lines::Set{Int}
end

"""
    opt_outs(path, rule)

The lines of `path` that the `# lint:` comments (`OPT_OUT`) take out of `rule`. A `-begin` without
an `-end` runs to the end of the file. A path that is no file (a method a macro defined has the file
`none`) has none.
"""
function opt_outs(path::AbstractString, rule::AbstractString)::OptOuts
    whole_file = false
    lines = Set{Int}()
    if !isfile(path)
        return OptOuts(whole_file, lines)
    end
    inside = false
    for (number, text) in enumerate(eachline(path))
        if inside
            push!(lines, number)
        end
        for found in eachmatch(OPT_OUT, text)
            if found[1] != rule
                continue
            end
            push!(lines, number)
            if found[2] == "file"
                whole_file = true
            elseif found[2] == "begin"
                inside = true
            elseif found[2] == "end"
                inside = false
            end
        end
    end
    return OptOuts(whole_file, lines)
end

"""
    opt_out_counts(files)

How many opt-out comments of each rule `files` carry (a `-begin`/`-end` pair is one), so the
exceptions stay visible beside the baseline.
"""
function opt_out_counts(files::AbstractVector{<:AbstractString})::Dict{String, Int}
    counts = Dict{String, Int}()
    for file in files
        for text in eachline(file)
            for found in eachmatch(OPT_OUT, text)
                if found[2] != "end"
                    counts[found[1]] = get(counts, found[1], 0) + 1
                end
            end
        end
    end
    return counts
end

"""The Julia files under `directories` of `repository`, `vendor` and hidden directories excluded."""
function repository_sources(repository::Repository, directories::Tuple{Vararg{String}})::Vector{String}
    found = String[]
    for directory in directories
        for (root, subdirectories, names) in walkdir(joinpath(repository.root, directory))
            filter!(name -> !startswith(name, ".") && name != "vendor", subdirectories)
            append!(found, joinpath(root, name) for name in names if endswith(name, ".jl"))
        end
    end
    return sort!(found)
end

"""The baseline entry left after `found` sites against `entry`: a note stays while its offender has a site, a count falls to `found`."""
remaining(entry::AbstractString, found::Integer)::Union{String, Int} = ifelse(found == 0, 0, entry)
remaining(entry::Integer, found::Integer)::Int = min(entry, found)

"""Whether `found` sites exceed baseline `entry`; a note allows any number."""
exceeds(found::Integer, entry::AbstractString)::Bool = false
exceeds(found::Integer, entry::Integer)::Bool = found > entry

"""Write `baseline` to the file at `path` in one rename, so a reader never sees half a file."""
function write_baseline!(baseline::AbstractDict, path::AbstractString)::String
    buffer = IOBuffer()
    TOML.print(buffer, baseline; sorted = true)
    staged = "$path.$(getpid())"
    write(staged, take!(buffer))
    return mv(staged, path; force = true)
end

"""
    ratchet!(repository, rule, sites; scopes = ("",))

Hold `rule`'s offenders to its table in `repository.baseline`. Sites that a `# lint:` comment naming the
rule opts out are dropped and counted in the log; the rest are tallied by key. A test fails, listing
them, on keys past their baseline entry; an entry the tally undercuts is lowered or deleted and the
file rewritten. A rule with no table is seeded with its tally. Returns the keys past the baseline.
Several testsets may share one rule's table, and a run may not measure all of it (a job's copy of the
tree lacks directories): each passes the prefixes `scopes` that begin the keys it measures, and only
entries under one of them can fall.
"""
function ratchet!(repository::Repository, rule::String, sites::AbstractVector{Site}; scopes::Tuple{Vararg{String}} = ("",))::Vector{String}
    skips = Dict{String, OptOuts}()
    measured = Dict{String, Int}()
    opted = 0
    for site in sites
        if !haskey(skips, site.file)
            skips[site.file] = opt_outs(site.file, rule)
        end
        if skips[site.file].whole_file || any(in(skips[site.file].lines), site.line:site.last_line)
            opted += 1
        else
            measured[site.key] = get(measured, site.key, 0) + 1
        end
    end
    if opted > 0
        @info "$rule: $opted site(s) opted out by `# lint: $rule`"
    end
    # ponytail: testsets on separate retest workers may rewrite at once; the rename is atomic, so
    # one lowering can be lost (the baseline stays higher, never wrong) and the next run redoes it.
    path = realpath(repository.baseline)
    baseline = TOML.parsefile(path)
    if !haskey(baseline, rule)
        baseline[rule] = measured
        write_baseline!(baseline, path)
        @warn "$rule: no table in $path; seeded with today's $(sum(values(measured); init = 0)) site(s)"
        return String[]
    end
    entries = baseline[rule]
    over = sort!([key for (key, found) in measured if !haskey(entries, key) || exceeds(found, entries[key])])
    improved = sort!([key for (key, entry) in entries if any(startswith(key, scope) for scope in scopes) && remaining(entry, get(measured, key, 0)) != entry])
    for key in improved
        left = remaining(entries[key], get(measured, key, 0))
        if left == 0
            delete!(entries, key)
        else
            entries[key] = left
        end
    end
    if !isempty(improved)
        write_baseline!(baseline, path)
        @info "$rule fell: baseline lowered in $path" improved
    end
    if !isempty(over)
        @error "$rule: offenders past the baseline in $path:\n" * join(["$key = $(measured[key])" for key in over], "\n")
    end
    @test isempty(over)
    return over
end

# Corset's own tests. Each rule reads deliberately bad code from `fixtures/`, kept out of `.jl`
# files so a linter of this tree does not read it.
using Test: @testset, @test, @test_logs, @test_throws
using TOML: TOML
using Corset: CONCRETE_RETURN_FIX, Repository, Site, ratchet!, offenders!, @call_sites, @opt_sites, float64_ops, abstract_fields, abstract_locals,
    boxed_closures, capturing_closures, concrete_arguments, concrete_returns, fatou_sites, float64_sites, hidden_inputs,
    inferred_methods, located_source, misplaced_imports, missing_annotations, module_structs, nothing_returns,
    one_letter_sites, place_imports!, present_directories, range_guards, repeated_prefix, repeated_statements,
    repository_sources, return_type_calls, struct_locations, struct_site, unmarked_effects, fix_where_returns,
    where_return_sites

const FIXTURES = joinpath(@__DIR__, "fixtures")
const SNIPPETS = TOML.parsefile(joinpath(FIXTURES, "snippets.toml"))

"""Write each `name => text` of `files` under `root`, making directories, and return `root`."""
function write_tree(root::AbstractString, files::AbstractVector{<:Pair})::String
    for (name, text) in files
        mkpath(dirname(joinpath(root, name)))
        write(joinpath(root, name), text)
    end
    return root
end

"""The path of `source.jl` holding the snippet of `rule` (`fixtures/snippets.toml`), in a fresh tree."""
snippet_file(rule::AbstractString)::String = joinpath(write_tree(mktempdir(), ["source.jl" => SNIPPETS[rule]["source"]]), "source.jl")

"""The `Site`s that `finder(path, located)` finds in the snippet of `rule`."""
function found_in(finder::Function, rule::AbstractString)::Vector{Site}
    path = snippet_file(rule)
    return finder(path, located_source(path))
end

"""The keys of `sites`."""
site_keys(sites::AbstractVector{Site})::Vector{String} = [site.key for site in sites]

"""The lines of `sites`."""
site_lines(sites::AbstractVector{Site})::Vector{Int} = [site.line for site in sites]

"""A module loaded from `fixtures/fixture_module.txt`, written as `fixture.jl` in the tree `root`."""
function load_fixture(root::AbstractString)::Module
    path = joinpath(write_tree(root, ["fixture.jl" => read(joinpath(FIXTURES, "fixture_module.txt"), String)]), "fixture.jl")
    fixture = Module(:Fixture)
    Base.include(fixture, path)
    return fixture
end

"""The files `repository_sources` finds under `src` of `repository`, relative to `root`."""
relative_sources(repository::Repository, root::AbstractString)::Vector{String} = [relpath(file, root) for file in repository_sources(repository, ("src",))]

"""Install in `bin` a `fatou` that prints `printed` (a `printf` format) and return `bin`."""
function fake_fatou(bin::AbstractString, printed::AbstractString)::String
    write_tree(bin, ["fatou" => "#!/bin/sh\nprintf '$printed'\n"])
    chmod(joinpath(bin, "fatou"), 0o755)
    return bin
end

"""The text `place_imports!` leaves in `files` (name => text) written into a fresh tree, which then has no misplaced import."""
function placed(files::AbstractVector{<:Pair})::Dict{String, String}
    repository = Repository(write_tree(mktempdir(), files))
    place_imports!(repository, (".",))
    @test isempty(misplaced_imports(repository, (".",)))
    return Dict(name => read(joinpath(repository.root, name), String) for (name, _) in files)
end

@testset "Corset" begin
    @testset "a Repository is strict by default" begin
        repository = Repository(".")
        @test repository.root == abspath(".")
        @test isnothing(repository.baseline)
        @test repository.one_letter_exempt == ()
        @test repository.skipped_directories == ()
    end

    @testset "without a baseline every offender's key is past it" begin
        repository = Repository(mktempdir())
        sites = [Site("first", "", 0), Site("second", "", 0), Site("second", "", 0)]
        @test (@test_logs (:error, r"rule: offenders past no baseline") offenders!(repository, "rule", sites)) == ["first", "second"]
        @test ratchet!(repository, "rule", Site[]) == String[]
    end

    @testset "a `# lint:` comment opts its lines out" begin
        text = "one() = 1 # lint: rule\ntwo() = 2\n# lint: rule-begin\nthree() = 3\n# lint: rule-end\nfour() = 4 # lint: other\n"
        root = write_tree(mktempdir(), ["source.jl" => text, "whole.jl" => "# lint: rule-file\none() = 1\n"])
        sites = [Site("line $line", joinpath(root, "source.jl"), line) for line in 1:6]
        @test offenders!(Repository(root), "rule", sites) == ["line 2", "line 6"]
        @test isempty(offenders!(Repository(root), "rule", [Site("whole", joinpath(root, "whole.jl"), 2)]))
    end

    @testset "with a baseline each key is held to its entry, and entries fall" begin
        root = mktempdir()
        baseline = joinpath(root, "baseline.toml")
        write(baseline, "")
        repository = Repository(root; baseline)
        sites = [Site("counted", "", 0), Site("counted", "", 0), Site("noted", "", 0)]
        @test isempty(@test_logs (:warn, r"seeded") offenders!(repository, "rule", sites))
        @test TOML.parsefile(baseline)["rule"] == Dict("counted" => 2, "noted" => 1)
        write(baseline, "[rule]\ncounted = 2\nnoted = \"kept: deliberate\"\n")
        @test isempty(offenders!(repository, "rule", [sites; Site("noted", "", 0)]))
        @test offenders!(repository, "rule", [sites; Site("counted", "", 0)]) == ["counted"]
        @test offenders!(repository, "rule", [Site("fresh", "", 0)]; scopes = ("noted",)) == ["fresh"]
        @test TOML.parsefile(baseline)["rule"] == Dict("counted" => 2)
        @test ratchet!(repository, "rule", [Site("counted", "", 0)]) == String[]
        @test TOML.parsefile(baseline)["rule"] == Dict("counted" => 1)
    end

    @testset "repository_sources skips hidden directories, and skipped ones when asked" begin
        root = write_tree(mktempdir(), ["src/a.jl" => "", "src/vendor/b.jl" => "", "src/.hidden/c.jl" => "", "src/notes.txt" => ""])
        @test relative_sources(Repository(root), root) == ["src/a.jl", "src/vendor/b.jl"]
        @test relative_sources(Repository(root; skipped_directories = ("vendor",)), root) == ["src/a.jl"]
        @test present_directories(Repository(root), ("src", "missing")) == ("src",)
    end

    root = mktempdir()
    fixture = load_fixture(root)
    repository = Repository(root)
    inferred = inferred_methods(fixture)

    @testset "hidden-input: a read of a mutable or non-constant global" begin
        @test unique(site_keys(hidden_inputs(fixture))) == ["counter"]
    end

    @testset "abstract-local: a local variable that infers no concrete type" begin
        @test site_keys(abstract_locals(repository, inferred)) == ["fixture.jl abstract_local"]
        @test isempty(abstract_locals(Repository(mktempdir()), inferred))
    end

    @testset "bang: a function that always returns nothing has a name ending in !" begin
        @test site_keys(unmarked_effects(repository, inferred)) == ["fixture.jl announce"]
    end

    @testset "closure: closures that capture data, and those holding a Core.Box" begin
        sites = Dict(site.key => site for site in capturing_closures(fixture))
        @test Set(keys(sites)) == Set(["fixture.jl adder", "fixture.jl boxed", "fixture.jl lineless"])
        @test site_keys(boxed_closures(fixture)) == ["fixture.jl boxed"]
        @testset "a closure built without line numbers sits at the function that creates it" begin
            fixture_lines = readlines(joinpath(root, "fixture.jl"))
            @test sites["fixture.jl lineless"].line == findfirst(startswith("@eval function lineless"), fixture_lines)
            @test sites["fixture.jl lineless"].file == joinpath(root, "fixture.jl")
        end
    end

    @testset "abstract-field, repeated-prefix: struct fields" begin
        structs = Dict(nameof(type) => type for type in module_structs(fixture))
        @test Set(keys(structs)) == Set([:Holder, :Plain, :SolverControls])
        @test abstract_fields(structs[:Holder]) == [:held]
        @test isempty(abstract_fields(structs[:Plain]))
        @test repeated_prefix(structs[:SolverControls]) == "solver"
        @test isnothing(repeated_prefix(structs[:Plain]))
        path = joinpath(root, "fixture.jl")
        @test struct_site(:Holder, struct_locations([path])) == Site("Holder", path, findfirst(==("struct Holder"), readlines(path)))
    end

    @testset "a struct is placed at its `struct` line, below its docstring" begin
        path = snippet_file("struct-line")
        lines = readlines(path)
        locations = struct_locations([path])
        @test locations == Dict(
            :Documented => (path, findfirst(startswith("struct Documented"), lines)),
            :Counter => (path, findfirst(endswith("struct Counter"), lines)),
            :Plain => (path, findfirst(startswith("struct Plain"), lines)),
            Symbol("Odd Name") => (path, findfirst(startswith("struct var\"Odd Name\""), lines)),
        )
        sites = [struct_site(name, locations) for name in (:Documented, :Counter)]
        @test offenders!(Repository(dirname(path)), "wide-struct", sites) == ["Counter"]
    end

    @testset "jet: JET reports as sites" begin
        errors = Site[]
        @call_sites "error analysis" errors target_modules = (fixture,) fixture.broken(1)
        @test !isempty(errors)
        @test all(site -> startswith(site.key, "error analysis: broken"), errors)
        dispatches = Site[]
        @opt_sites "optimization analysis" dispatches target_modules = (fixture,) fixture.unstable(fixture.make_box())
        @test !isempty(dispatches)
        clean = Site[]
        @call_sites "error analysis" clean target_modules = (fixture,) fixture.reads_limit(1)
        @test isempty(clean)
    end

    @testset "float64_ops: Float64 operations in optimized IR" begin
        @test float64_ops(fixture.widened, (Float32,)) > 0
        @test float64_ops(fixture.narrow, (Float32,)) == 0
    end

    @testset "nothing-return: a declared Union{Nothing, …} result" begin
        @test site_keys(found_in(nothing_returns, "nothing-return")) == ["maybe"]
    end

    @testset "range-guard: floatmin, floatmax, exp's range edge, isfinite of exp" begin
        @test site_keys(found_in(range_guards, "range-guard")) == ["guard", "edge", "finite"]
    end

    @testset "repeated-statement: a statement repeated in one block" begin
        sites = found_in(repeated_statements, "repeated-statement")
        @test length(sites) == 1
        @test startswith(only(sites).key, "twice: ")
        @test only(sites).line == 3
    end

    @testset "return-type: Core.Compiler.return_type" begin
        @test site_lines(found_in(return_type_calls, "return-type")) == [1]
    end

    @testset "concrete-arg: an argument annotated with a concrete container it does not resize" begin
        @test site_lines(found_in(concrete_arguments, "concrete-arg")) == [1]
    end

    @testset "concrete-return: a result annotated with a concrete type, `Matrix{T}` included" begin
        sites = found_in((path, located) -> concrete_returns(path, located, Base), "concrete-return")
        @test site_keys(sites) == ["source.jl fixed", "source.jl squared"]
        logged = (:error, Regex("Fix: \\Q$CONCRETE_RETURN_FIX\\E"))
        @test (@test_logs logged offenders!(Repository(mktempdir()), "concrete-return", sites; fix = CONCRETE_RETURN_FIX)) == site_keys(sites)
    end

    @testset "float64: Float64 tokens and untyped float literals" begin
        @test site_lines(float64_sites(snippet_file("float64"))) == [1, 1]
    end

    @testset "annotation: every argument and result annotated" begin
        @test site_keys(found_in(missing_annotations, "annotation")) == ["source.jl untyped", "source.jl no_result"]
    end

    @testset "one-letter: one-letter variable names, with exemptions opt-in" begin
        path = snippet_file("one-letter")
        @test length(one_letter_sites(Repository(dirname(path)), path)) == 2
        @test length(one_letter_sites(Repository(dirname(path); one_letter_exempt = (:p,)), path)) == 1
    end

    @testset "fatou: findings of `fatou lint`" begin
        tree = write_tree(mktempdir(), ["source.jl" => "one() = 1\n"])
        bin = fake_fatou(mktempdir(), "source.jl:3:5: warning[unused-binding] unused\\nchecked 1 file(s): 1 finding\\n")
        path = ENV["PATH"]
        ENV["PATH"] = "$bin:$path"
        try
            @test fatou_sites(Repository(tree), (".",)) == [Site("source.jl unused-binding", joinpath(tree, "source.jl"), 3)]
            fake_fatou(bin, "checked 1 file(s): clean\\n")
            @test isempty(fatou_sites(Repository(tree), (".",)))
            fake_fatou(bin, "source.jl: parse error\\n")
            @test_throws ErrorException fatou_sites(Repository(tree), (".",))
        finally
            ENV["PATH"] = path
        end
    end

    @testset "misplaced-import: imports sit in the files that use them" begin
        snippets = SNIPPETS["misplaced-import"]
        tree = write_tree(mktempdir(), ["main.jl" => snippets["main"], "child.jl" => snippets["child"]])
        @test site_keys(misplaced_imports(Repository(tree), (".",))) == ["main.jl a", "main.jl c", "main.jl D"]
        place_imports!(Repository(tree), (".",))
        @test isempty(misplaced_imports(Repository(tree), (".",)))
        @testset "an import no file uses is deleted, one only an included file uses moves there" begin
            @test read(joinpath(tree, "main.jl"), String) == "module Main1\nusing A: b\ninclude(\"child.jl\")\nf() = b\nend\n"
        end
        @testset "a `using M: a, b` list splits across files; a name both files use stays put" begin
            @test read(joinpath(tree, "child.jl"), String) == "using A: a\nusing C: c\ng() = a + b + c\n"
        end
        @testset "an opted-out import and a bare `using` stay" begin
            kept_tree = write_tree(mktempdir(), ["kept.jl" => snippets["kept"]])
            place_imports!(Repository(kept_tree), (".",))
            @test read(joinpath(kept_tree, "kept.jl"), String) == snippets["kept"]
        end
    end
end

@testset "short-form `where` binds the method, not the return annotation" begin
    @test fix_where_returns("f(x::V{E})::Vector{E} where {E<:Real} = x\n") ==
        "(f(x::V{E})::Vector{E}) where {E<:Real} = x\n"
    @testset "no argument uses the variable, so the annotation may be deliberate" begin
        kept = "g()::Vector{T} where {T} = T[]\n"
        @test fix_where_returns(kept) == kept
    end
    @testset "the long form and a method-level `where` are left alone" begin
        for kept in (
                "function f(x::V{E})::Vector{E} where {E}\n    x\nend\n",
                "f(x::V{E}) where {E} = x\n",
                "(f(x::V{E})::Vector{E}) where {E} = x\n",
            )
            @test fix_where_returns(kept) == kept
            path = tempname()
            write(path, kept)
            @test isempty(where_return_sites(path))
        end
    end
end

@testset "a script without a module keeps the imports its included files use" begin
    result = placed([
        "main.jl" => "using A: a\ninclude(\"child.jl\")\n",
        "child.jl" => "g() = a\n",
    ])
    @test result["child.jl"] == "using A: a\ng() = a\n"
end

@testset "annotation rules" begin
    check(text::String, rule::Function) = (
        path = tempname() * ".jl";
        write(path, text);
        rule(path, located_source(path))
    )
    @testset "a keyword splat needs no annotation, and Bool is an allowed result" begin
        text = "f(x::T; options...)::Bool where {T} = true\n"
        @test isempty(check(text, missing_annotations))
        @test isempty(check(
            text,
            (path, located) -> concrete_returns(path, located, Main),
        ))
    end
    @testset "a positional argument still needs one" begin
        @test length(check("f(x)::Bool = true\n", missing_annotations)) == 1
    end
end

@testset "a name used only inside a macro call counts as used" begin
    result = placed([
        "main.jl" => "using A: a\ninclude(\"child.jl\")\n",
        "child.jl" => "@testset \"x\" begin\n    @test f(a(2))\nend\n",
    ])
    @test result["child.jl"] == "using A: a\n@testset \"x\" begin\n    @test f(a(2))\nend\n"
end

module Probe
    function generic(point::AbstractVector{E})::E where {E <: Real}
        total = zero(E)
        for entry in point
            total += entry
        end
        return total
    end
    off(::Nothing)::Nothing = nothing
    off(value::Real)::typeof(value) = value
    function catches()::Nothing
        try
            error("probe")
        catch exception
            return nothing
        end
    end
    function each_part(body::B, parts::Integer)::Nothing where {B}
        foreach(body, 1:parts)
        return nothing
    end
    struct Buffer{E <: Real}
        entries::Vector{E}
    end
    function Buffer(point::AbstractVector{E}, extra::Integer)::Buffer{E} where {E <: Real}
        entries = Vector{E}(undef, length(point) + extra)
        return Buffer(entries)
    end
    function passing(thunk::F) where {F}
        try
            return thunk()
        catch exception
            rethrow(exception)
        end
    end
end

@testset "abstract locals and bang names read what ran" begin
    Probe.generic(Float32[1, 2])
    Probe.off(nothing)
    Probe.off(1.0f0)
    Probe.catches()
    Probe.each_part(identity, 2)
    Probe.each_part(string, 2)
    Probe.passing(() -> nothing)
    Probe.Buffer(Float32[1, 2], 1)
    repository = Repository(@__DIR__)
    inferred = inferred_methods(Probe)
    @testset "a generic method or constructor is typed at the types it was called with, and a catch variable is skipped" begin
        @test isempty(abstract_locals(repository, inferred))
    end
    @testset "a nothing method beside a valued one is not a procedure; a lone one is" begin
        keys = [site.key for site in unmarked_effects(repository, inferred)]
        @test !any(contains("off"), keys)
        @test any(contains("catches"), keys)
    end
    @testset "a generic procedure called with several types is one site" begin
        keys = [site.key for site in unmarked_effects(repository, inferred)]
        @test count(contains("each_part"), keys) == 1
    end
    @testset "a method returning a call to its argument gets no verdict from what its callers passed" begin
        @test !any(contains("passing"), [site.key for site in unmarked_effects(repository, inferred)])
    end
end

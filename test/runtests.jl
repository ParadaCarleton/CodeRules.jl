using Test: @testset, @test
using CodeRules:
    CodeRules,
    Repository,
    place_imports!,
    misplaced_imports,
    fix_where_returns,
    where_return_sites

"""The text `place_imports!` leaves in `files` (name => text) written into a fresh tree."""
function placed(files::AbstractVector{<:Pair})::Dict{String, String}
    root = mktempdir()
    foreach(((name, text),) -> write(joinpath(root, name), text), files)
    repository = Repository(root, joinpath(root, "baseline.toml"), ())
    place_imports!(repository, (".",))
    @test isempty(misplaced_imports(repository, (".",)))
    return Dict(name => read(joinpath(root, name), String) for (name, _) in files)
end

@testset "imports sit in the files that use them" begin
    main = """
    module Main1
    using A: a, b
    using C: c
    import D
    include("child.jl")
    f() = b
    end
    """
    result = placed(["main.jl" => main, "child.jl" => "g() = a + b + c\n"])
    @testset "an import no file uses is deleted, one only an included file uses moves there" begin
        @test result["main.jl"] ==
            "module Main1\nusing A: b\ninclude(\"child.jl\")\nf() = b\nend\n"
    end
    @testset "a `using M: a, b` list splits across files; a name both files use stays put" begin
        @test result["child.jl"] == "using A: a\nusing C: c\ng() = a + b + c\n"
    end
    @testset "an opted-out import and a bare `using` stay" begin
        kept = "import MKL # fatou-ignore unused-import\nusing Test\n"
        @test placed(["kept.jl" => kept])["kept.jl"] == kept
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
        rule(path, CodeRules.located_source(path))
    )
    @testset "a keyword splat needs no annotation, and Bool is an allowed result" begin
        text = "f(x::T; options...)::Bool where {T} = true\n"
        @test isempty(check(text, CodeRules.missing_annotations))
        @test isempty(check(
            text,
            (path, located) -> CodeRules.concrete_returns(path, located, Main),
        ))
    end
    @testset "a positional argument still needs one" begin
        @test length(check("f(x)::Bool = true\n", CodeRules.missing_annotations)) == 1
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
end

@testset "abstract locals and bang names read what ran" begin
    Probe.generic(Float32[1, 2])
    Probe.off(nothing)
    Probe.off(1.0f0)
    Probe.catches()
    repository = Repository(@__DIR__, joinpath(@__DIR__, "baseline.toml"), ())
    inferred = CodeRules.inferred_methods(Probe)
    @testset "a generic method is typed at the types it was called with, and a catch variable is skipped" begin
        @test isempty(CodeRules.abstract_locals(repository, inferred))
    end
    @testset "a nothing method beside a valued one is not a procedure; a lone one is" begin
        keys = [site.key for site in CodeRules.unmarked_effects(repository, inferred)]
        @test !any(contains("off"), keys)
        @test any(contains("catches"), keys)
    end
end

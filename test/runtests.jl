using Test: @testset, @test
using CodeRules: Repository, place_imports!, misplaced_imports, fix_where_returns, where_return_sites

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
        @test result["main.jl"] == "module Main1\nusing A: b\ninclude(\"child.jl\")\nf() = b\nend\n"
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
    @test fix_where_returns("f(x::V{E})::Vector{E} where {E<:Real} = x\n") == "(f(x::V{E})::Vector{E}) where {E<:Real} = x\n"
    @testset "no argument uses the variable, so the annotation may be deliberate" begin
        kept = "g()::Vector{T} where {T} = T[]\n"
        @test fix_where_returns(kept) == kept
    end
    @testset "the long form and a method-level `where` are left alone" begin
        for kept in ("function f(x::V{E})::Vector{E} where {E}\n    x\nend\n", "f(x::V{E}) where {E} = x\n", "(f(x::V{E})::Vector{E}) where {E} = x\n")
            @test fix_where_returns(kept) == kept
            path = tempname()
            write(path, kept)
            @test isempty(where_return_sites(path))
        end
    end
end

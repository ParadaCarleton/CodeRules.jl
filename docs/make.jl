using Documenter, Corset

DocMeta.setdocmeta!(Corset, :DocTestSetup, :(using Corset); recursive = true)

makedocs(;
    sitename = "Corset.jl",
    authors = "Carlos Parada",
    modules = [Corset],
    format = Documenter.HTML(canonical = "https://paradacarleton.github.io/Corset.jl/stable", size_threshold_warn = 200 * 1024),
    pages = ["Home" => "index.md"],
    warnonly = false,
)

deploydocs(repo = "github.com/ParadaCarleton/Corset.jl.git", push_preview = true)

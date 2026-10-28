# Compiles the `check` path while Corset precompiles, so a run of `corset` reuses the cached code
# and spends its time and memory on the project, not on the compiler.

# fatou-ignore unused-import: the macro expansion names the module
using PrecompileTools: PrecompileTools, @compile_workload

"""A package for the precompile workload to check: it holds one finding for a module rule to report."""
module WorkloadPackage
    const COUNTER = Ref(0)
    bump(x) = x + COUNTER[]
    struct Holder
        held::Any
    end
end

@compile_workload begin
    root = mktempdir()
    mkpath(joinpath(root, "src"))
    write(joinpath(root, "Project.toml"), "name = \"WorkloadPackage\"\n")
    write(
        joinpath(root, "src", "WorkloadPackage.jl"),
        "module WorkloadPackage\nconst COUNTER = Ref(0)\nbump(x) = x + COUNTER[]\nstruct Holder\n    held::Any\nend\nend\n",
    )
    config = with_overrides(load_config(root), true, ["fatou" => :allow])
    findings, _ = run_rules(config, root; mod = WorkloadPackage)
    for format in ("human", "concise")
        print_findings(devnull, root, findings, format)
    end
    print_rules(devnull, config)
    exit_code(findings, false)
    redirect_stderr(devnull) do
        redirect_stdout(devnull) do
            main(["rules", root])
            main(["check", root, "--no-load", "--pedantic"])
        end
    end
end

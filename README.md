# CodeRules

Code-quality rules for Julia packages, run as tests. Each rule is a function that reads a loaded
module (its lowered and inferred code, bindings and types) or a source file, and returns the `Site`s
it finds. `ratchet!` turns those sites into one `@test`.

By default every site of every rule fails. Two opt-in settings relax that for an existing codebase:

- a baseline file, which allows the sites it lists and lowers itself as they go away (a ratchet);
- per-rule exemptions on the `Repository` (allowed one-letter names, skipped directories).

A `# lint: RULE` comment on a site's line opts that one site out.

## Install

```julia
pkg> add https://github.com/ParadaCarleton/CodeRules.jl
```

Julia 1.13 or newer (JuliaSyntax kind `macro_name`).

## Use

```julia
using Test
using CodeRules: Repository, ratchet!, hidden_inputs, boxed_closures, located_source, nothing_returns, float64_sites,
    repository_sources
using MyPackage

const RULES = Repository(pkgdir(MyPackage))

@testset "code rules" begin
    ratchet!(RULES, "hidden-input", hidden_inputs(MyPackage))
    ratchet!(RULES, "closure-box", boxed_closures(MyPackage))
    files = repository_sources(RULES, ("src",))
    ratchet!(RULES, "nothing-return", [site for file in files for site in nothing_returns(file, located_source(file))])
end
```

Each failing `ratchet!` logs the offending keys. `offenders!` returns them without a test. Pass
`fix = "…"` to either to say in the log how to repair an offender; `CONCRETE_RETURN_FIX` is the
text for `concrete-return`.

### A baseline

```julia
const RULES = Repository(pkgdir(MyPackage); baseline = joinpath(@__DIR__, "code_baseline.toml"))
```

The baseline is a TOML file with one table per rule. An integer allows that many sites under a key; a
string (a note, such as `"kept: hot loop"`) allows any number. A rule with no table is seeded with
today's sites. When a run finds fewer sites than an entry allows, the entry is lowered or deleted and
the file rewritten. A testset that measures only part of a rule's keys passes their prefixes as
`scopes`, so entries outside them never fall.

### Exemptions

```julia
Repository(root; one_letter_exempt = (:p,), skipped_directories = ("vendor",))
```

### Opt-out comments

`# lint: RULE` opts its own line out of `RULE`. `# lint: RULE-begin` … `# lint: RULE-end` opts out
the lines between, and `# lint: RULE-file` the whole file. Write the reason after the comment.

## Rules

A rule name is the one the caller passes to `ratchet!` and writes in opt-out comments; the names
below are conventions.

| Rule | Function | Finds |
| --- | --- | --- |
| `hidden-input` | `hidden_inputs(mod)` | reads of a non-constant or mutable global, or a `ScopedValue` |
| `abstract-local` | `abstract_locals(repo, inferred_methods(mod))` | local variables that infer no concrete type |
| `bang` | `unmarked_effects(repo, inferred_methods(mod))` | functions that always return `nothing` without a `!` |
| `closure` | `capturing_closures(mod)` | closures that capture data |
| `closure-box` | `boxed_closures(mod)` | closures holding a `Core.Box` (a captured variable that is rebound) |
| `abstract-field` | `abstract_fields(type)` for `module_structs(mod)` | struct fields of an abstract type, or of a container of one |
| `repeated-prefix` | `repeated_prefix(type)` | field names that repeat a word the type should say once |
| `wide-struct` | `fieldcount` of `module_structs(mod)` | structs with more fields than the caller's limit |
| `nothing-return` | `nothing_returns(file, located)` | declared `Union{Nothing, …}` results |
| `range-guard` | `range_guards(file, located)` | `floatmin`/`floatmax`, `exp`'s range edges (88, 709), `isfinite(exp(…))` |
| `repeated-statement` | `repeated_statements(file, located)` | a statement repeated in one block |
| `return-type` | `return_type_calls(file, located)` | calls of `Core.Compiler.return_type` |
| `concrete-arg` | `concrete_arguments(file, located)` | arguments annotated `Vector`, `Matrix`, `Array` or `Dict` and never resized |
| `concrete-return` | `concrete_returns(file, located, mod)` | results annotated with a concrete type, `Vector{E}` and `Matrix{T}` included; `AbstractMatrix{T}` passes |
| `annotation` | `missing_annotations(file, located)` | methods with an unannotated argument or result |
| `float64` | `float64_sites(file)` | `Float64` tokens and untyped float literals |
| `one-letter` | `one_letter_sites(repo, file)` | one-letter variable names |
| `fatou` | `fatou_sites(repo, directories)` | findings of [Fatou](https://github.com/jolars/fatou) (`fatou` on `PATH`) |
| `misplaced-import` | `misplaced_imports(repo, directories)` | imports their file does not use; `place_imports!` moves them |
| `where-return` | `where_return_sites(file)` | short-form definitions whose `where` binds the return annotation; `fix_where_returns!` parenthesizes them |
| `jet` | `@call_sites`, `@opt_sites` | `JET.@report_call` and `JET.@report_opt` reports |

`located` is `located_source(file)`, the parsed file. `struct_site(name, struct_locations(files))`
places a struct rule's site at the `struct` line, below any docstring. `float64_ops(f, types)` counts
Float64 operations in the optimized IR of one call, for a Float32 code path.

## Test

```julia
pkg> test CodeRules
```

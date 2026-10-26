# CodeRules

Project-specific code rules for Julia packages, run from the test suite. Each rule returns `Site`s;
`ratchet!` holds them to a baseline file, and a package that wants no exceptions asserts the list is empty.
Rules: hidden inputs, abstract locals, capturing closures, wide and abstractly typed structs, missing or
concrete annotations, `Float64` literals, one-letter names, misplaced imports (`place_imports!` fixes them),
short-form `where` bugs (`fix_where_returns!` fixes them), Fatou and JET findings.

Extracted from irv-extremism `packages/CodeRules`.

Licensed under the Mozilla Public License 2.0 (`LICENSE`).

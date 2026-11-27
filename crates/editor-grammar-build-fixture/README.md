# editor-grammar-build-fixture

A test fixture: a grammar-source crate, shaped as a package's is
(`packages/languages/rust`), whose one grammar, `broken`, does not compile.
`broken/src/parser.c` is one `#error` line, clang-formatted and checked
like the rest of the repository's C.

It is the source of the set build's failure check,
`packages/languages/LanguagesTest/Linked/Languages/Grammars/Real/SourceSet.lean`:
a package `broken-grammar`, written in a temporary directory, names this
crate's `Cargo.toml` as its `editorGrammarSources` input file, and the
set's build of it must fail naming the package and the grammar
(`docs/design/packages.md`, "A package's grammars").

## Why it doesn't break the workspace build

`build.rs` calls `editor-grammar-build`, which records a grammar that fails
to compile, warns (`cargo:warning`) and carries on rather than panic. So
`cargo build --workspace` passes, with the warning, and the binary prints
the report, one line `failed<TAB>broken<TAB><reason>`, and the compiler's
output on standard error. The set's build reads the line and fails. That is
also why it can be an ordinary member of the root workspace: the failure
check's Cargo run builds it in the root's `target/`, the build cache every
set build in the gate writes.

The editor never links it.

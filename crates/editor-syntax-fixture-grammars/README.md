# editor-syntax-fixture-grammars

A test fixture: the six former built-in grammars (`rust`, `json`,
`markdown`, `markdown_inline`, `toml` and `lean`), which the `languages`
package ships, built as native grammar libraries for the core's tests from
the package's pinned sources, with the package's queries beside them. The
core's tests load their grammars from here, since they depend on no
package (`crates/editor-syntax-treesitter`, "How grammars are loaded").
The editor never links it (`deny.toml`).

## What it builds, and the layout

`build.rs` calls `editor-grammar-build` with the six grammars: the four
crates.io grammar crates this crate takes as build-dependencies, at exactly
the pins and features of `packages/languages/rust/Cargo.toml` (markdown's
two from the subdirectories of `tree-sitter-md`), and `lean` from the
vendored directory `vendor/tree-sitter-lean`. It fails Cargo on a grammar
that does not build. It then copies each grammar's queries from the
package's `packages/languages/grammars/queries/<name>/`, so the core's
tests draw with exactly what ships:

```text
<DIRECTORY>/libtree-sitter-<name>.dylib      (.so elsewhere)
<DIRECTORY>/queries/<name>/highlights.scm    every grammar
<DIRECTORY>/queries/<name>/injections.scm    rust, markdown, markdown_inline
<DIRECTORY>/queries/rust/textobjects.scm
<DIRECTORY>/queries/rust/indents.scm
<DIRECTORY>/queries/<name>/rendered.scm      markdown, markdown_inline
<DIRECTORY>/queries/markdown/rendered-injections.scm
```

This is the layout of a package's staged `grammars/` directory, so a Lean
test declares a grammar with its library and `queries/<name>` as it would
a package's. `DIRECTORY` is `OUT_DIR`, published to the crate as
`EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY`.

## Files

- `build.rs`: the build and the staged queries, above.
- `src/lib.rs`: `DIRECTORY`, and a `Grammar` constant for each of the six
  (`RUST`, `JSON`, `MARKDOWN`, `MARKDOWN_INLINE`, `TOML`, `LEAN`, and `ALL`
  `json` first, as the adapter's table listed them): its name, symbol,
  library path, whether
  it is reparsed incrementally, and its queries' texts, read from the
  staged files. Its unit tests pin that each library and query file is
  where the layout puts it, and that each constant is the staged file.
- `src/main.rs`: prints `DIRECTORY`, for `mise run ffi-test` to hand to
  the Lean test programs.

## Who uses it

- `editor-syntax-treesitter`'s tests and its `round` example, by a
  dev-dependency.
- `editor-ffi`'s tests, by a dev-dependency.
- Lean's `contract-test`, `ffi-test`, `config-test` and the packages'
  linked tests, which `mise run ffi-test` hands the directory as an
  argument.

## Why a build-script product, not a `cdylib`

As for `editor-syntax-fixture-ini`: a Cargo `cdylib`'s path cannot reach
another crate's tests on stable Cargo, and a Rust `cdylib` does not export
the C symbols of a static archive linked into it. The grammar crates are
build-dependencies with the same features as the `languages` package's
grammar-source crate's, so in the dev profile Cargo builds one unit of
each for both build scripts; the build script compiles each grammar's C
once more, as a shared library, in the profile being built. The vendored
`lean` is no dependency, so no archive of its 49 MB parser is built.

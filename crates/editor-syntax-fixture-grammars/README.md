# editor-syntax-fixture-grammars

A test fixture: the six grammars the syntax adapter compiles in (`rust`,
`json`, `markdown`, `markdown_inline`, `toml` and `lean`), built as native
grammar libraries from the same pinned sources, with the queries the
adapter ships for each beside them. The core's tests load their grammars
from here, since the adapter's compiled-in table is hidden from every test
but its own table tests (`crates/editor-syntax-treesitter`, "How grammars
are loaded"). The editor never links it (`deny.toml`).

## What it builds, and the layout

`build.rs` calls `editor-grammar-build` with the six grammars, each from
the grammar crate this crate depends on at exactly the adapter's pin
(markdown's two from the subdirectories of `tree-sitter-md`), and fails
Cargo on a grammar that does not build. It then copies each grammar's
queries from the source directory the build reports, plus rust's
`textobjects.scm` and `indents.scm` from the adapter's `queries/rust/`:

```text
<DIRECTORY>/libtree-sitter-<name>.dylib      (.so elsewhere)
<DIRECTORY>/queries/<name>/highlights.scm    every grammar
<DIRECTORY>/queries/<name>/injections.scm    rust, markdown, markdown_inline
<DIRECTORY>/queries/rust/textobjects.scm
<DIRECTORY>/queries/rust/indents.scm
```

This is the layout of a package's staged `grammars/` directory, so a Lean
test declares a grammar with its library and `queries/<name>` as it would
a package's. `DIRECTORY` is `OUT_DIR`, published to the crate as
`EDITOR_SYNTAX_FIXTURE_GRAMMARS_DIRECTORY`.

## Files

- `build.rs`: the build and the staged queries, above.
- `src/lib.rs`: `DIRECTORY`, and a `Grammar` constant for each of the six
  (`RUST`, `JSON`, `MARKDOWN`, `MARKDOWN_INLINE`, `TOML`, `LEAN`, and `ALL`
  in the adapter's table's order): its name, symbol, library path, whether
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
normal dependencies, not build-dependencies, so Cargo builds the very units
the adapter already builds and compiles no grammar's archive again for the
host; the build script compiles each grammar's C once more, as a shared
library, in the profile being built.

# Vendored sources

Third-party code copied into this repository because no published package
fits. Each copy is upstream's, unmodified: it is never edited here, only
replaced by a newer copy of upstream. Nothing here is a workspace member (the
root `Cargo.toml`'s `exclude`), and `mise run c-fmt` leaves its C alone.

## `tree-sitter-lean/`: the Lean 4 grammar

- **What**: the tree-sitter grammar for Lean 4, with its Rust binding (crate
  `tree-sitter-lean`, version `0.2.0`; this file holds the version, since
  no `Cargo.toml` names the copy and Cargo checks no version of it). The
  `languages` package's grammar-source crate (`packages/languages/rust`)
  compiles it, as a directory source of `editor-grammar-build`, into the
  library of the grammar `lean` the package ships, and the test fixture
  `crates/editor-syntax-fixture-grammars` does the same for the core's
  tests. No crate depends on the copy.
- **Why vendored**: there is no usable crates.io crate. The one Lean grammar
  crate, `tree-sitter-lean4`, has a normal dependency on `tree-sitter ^0.25`,
  which cannot coexist with the pinned library; `tree-sitter-lean` is not
  published. `packages/languages/rust/Cargo.toml` records the alternatives
  set aside.
- **Upstream**: <https://github.com/Julian/tree-sitter-lean>, commit
  `0d28e5d6e8c4755f5df7ef9bde3b6ec6f59fae94` (2026-11-01).
- **Licence**: MIT, `Copyright (c) 2024 Julian Berman`; the notice is
  `tree-sitter-lean/LICENSE`.
- **Files**: exactly upstream's crate `include` set, plus its licence:
  - `Cargo.toml`, `LICENSE`, `grammar.js`;
  - `bindings/rust/build.rs`, `bindings/rust/lib.rs`;
  - `queries/folds.scm`, `queries/highlights.scm`, `queries/indents.scm`,
    `queries/injections.scm`, `queries/locals.scm`;
  - `src/parser.c`, `src/scanner.c`, `src/grammar.json`,
    `src/node-types.json`;
  - `src/tree_sitter/alloc.h`, `src/tree_sitter/array.h`,
    `src/tree_sitter/parser.h`.

  The highlights query comes from the same commit as the grammar, so it cannot
  drift from the grammar's node types.

### Updating it

Copy the same file list from the new upstream commit, then bump the commit
(and the version, if upstream's changed) here, in
`packages/languages/rust/Cargo.toml`'s comment and in the `lean` row of
`packages/languages/README.md`; copy the new `queries/highlights.scm` to
`packages/languages/grammars/queries/lean/highlights.scm` and the new
`LICENSE` to `packages/languages/grammars/licenses/tree-sitter-lean`; and
re-run the contract:

```sh
git clone https://github.com/Julian/tree-sitter-lean /tmp/tree-sitter-lean
git -C /tmp/tree-sitter-lean checkout <commit>
for f in Cargo.toml LICENSE grammar.js \
    bindings/rust/build.rs bindings/rust/lib.rs \
    queries/folds.scm queries/highlights.scm queries/indents.scm \
    queries/injections.scm queries/locals.scm \
    src/parser.c src/scanner.c src/grammar.json src/node-types.json \
    src/tree_sitter/alloc.h src/tree_sitter/array.h src/tree_sitter/parser.h; do
  cp "/tmp/tree-sitter-lean/$f" "vendor/tree-sitter-lean/$f"
done
cargo test -p editor-syntax-treesitter --test contract
mise run syntax-bench
```

`mise run syntax-bench` re-measures a round on the largest Lean file; record
its figures, dated, in `docs/design/rust-library.md`.

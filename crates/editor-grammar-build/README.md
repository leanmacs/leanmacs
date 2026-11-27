# editor-grammar-build

Compiles a package's pinned grammar sources into the shared libraries a
set's build stages (`docs/design/packages.md`, "A package's grammars",
"From source"). A package's grammar-source crate (`packages/languages/rust`)
calls `build` from its build script with the grammars it declares; its
binary prints the report the set's build reads. The crate docs
(`src/lib.rs`) say who uses it, what it compiles, why a dependency's
directory is found with `cargo metadata`, and why a grammar that fails to
compile is recorded rather than panicked on. The editor never links it
(`deny.toml`).

## Files

- `src/lib.rs`: the core, `build_with`, over the three ports, the report's
  text, and the entry `build`, the one place that reads the build script's
  environment.
- `src/ports.rs`: the ports, `Locate`, `SourceTree` and `Compile`.
- `src/cargo_metadata.rs`, `src/cc_compiler.rs`, `src/real_tree.rs`: the
  real adapters, `cargo metadata`, the C compiler `cc` finds, and the disk.
- `src/tests.rs`: the core's tests, on hand-written fakes of the ports.
- `tests/compile.rs`: the real compiler on C sources the test writes into a
  temporary directory of its own: one links, one fails with its output.
- `tests/locate.rs`: the real locator on this crate's own dependency `cc`,
  and a name that is none of its dependencies.
- `build.rs`: hands the tests the target and host triples, which Cargo sets
  for a build script alone.

## Who uses it

- `languages-grammar-sources` (`packages/languages/rust`), the `languages`
  package's grammars, by a build-dependency.
- `editor-grammar-build-fixture`, whose one grammar does not compile, for
  the set build's failure check, by a build-dependency.

import Lake

open Lake DSL System

/-! A fixture package outside the core that holds Rust (docs/design/packages.md,
"Rust in a package"), used by tests alone: it shows a package bringing a
crate of its own and the glue that binds it, which the package-set build
links into the set's editor through the one Rust archive it generates from
the set (the core's facet `editorRust`).

Its lakefile is Lean and not TOML, as every other fixture's is: a TOML
lakefile cannot declare a target that compiles C, a library's
`moreLinkObjs`, or the target that declares the crate.

- `editorRustCrate` declares the crate: its manifest, `rust/Cargo.toml`.
  The core's build finds it by this target's name, in every package of a set
  (`editorRustCrates`), with no list kept by hand.
- `echoGlue.o` is the package's glue, `ffi/glue.c`, compiled against the
  toolchain's `lean.h`.
- `Echo` is the package's library: the port, its pure model, its contract,
  the pure checksum its replies carry, the service as a running job
  reaches it (`Echo.Job`), its list of packages and its entry module. `EchoReal` is the Rust-backed binding alone, whose
  `moreLinkObjs` is the glue, so the glue is linked into exactly the
  executables that import `Echo.Real`: the set's editor, through the entry
  module, and the linked test.
- `echo-test` is its test driver (`lake test`): the contract against the
  model, which needs no Rust, rooted at `EchoTest/Model.lean`.
- `EchoTest` holds the test modules, `EchoTest/Linked.lean` among them: the
  root of the executable the core's `editorLinked` facet links as the editor
  is linked, which runs the contract against the binding.

Every Lean linter is on and a warning fails the build, as in the core, and
the build's own linters, the wait linters, are loaded as a Lean plugin as
the core's libraries load them (`lintPlugin`; `lean/Lint/Wait.lean`). -/

package echo where
  testDriver := "«echo-test»"
  leanOptions := #[⟨`linter.all, true⟩, ⟨`warningAsError, true⟩]

require «editor-core» from ".." / ".." / ".." / "lean"

/-- The core's build linters as a Lean plugin, which each library and the
test driver load (the core's `lintPlugin`). It is named on them, not on the
package: the formatter elaborates this file under the package's own
plugins, and the plugin is not for this file. -/
def lintPlugin : TargetArray Dynlib :=
  #[`@«editor-core»/lintShared]

/-- The package's crate: the path of its manifest. -/
target editorRustCrate pkg : FilePath :=
  return Job.pure (pkg.dir / "rust" / "Cargo.toml")

/-- The package's glue (`ffi/glue.c`), compiled against the toolchain's own
`lean.h`. Nothing lints C for us, so every warning is an error. -/
target echoGlue.o pkg : FilePath := do
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  buildLeanO (pkg.buildDir / "ffi" / "glue.o") srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

/-- The port, its model, its contract and the entry module: every module of
the package but its tests and the binding. -/
@[default_target] lean_lib Echo where
  globs :=
  #[.one `Echo, .one `Echo.Model, .one `Echo.Contract, .one `Echo.Checksum, .one `Echo.Job,
    .one `Echo.Packages, .one `Echo.EditorPackage]
  plugins := lintPlugin

/-- The Rust-backed binding, with the package's glue. -/
@[default_target] lean_lib EchoReal where
  roots := #[`Echo.Real]
  moreLinkObjs := #[echoGlue.o]
  plugins := lintPlugin

/-- The test modules. -/
@[default_target] lean_lib EchoTest where
  globs := #[.submodules `EchoTest]
  plugins := lintPlugin

/-- The test driver: the tests that need no Rust. -/
lean_exe «echo-test» where
  root := `EchoTest.Model
  plugins := lintPlugin

import Lake

open Lake DSL System

/-! A fixture package outside the core that holds Rust (docs/design/packages.md,
"Rust in a package"), used by tests alone: it shows a package shipping its
Rust as a library of its own, loaded by the core when the editor starts,
and the glue that binds it (docs/design/packages.md, "A package's library,
staged and loaded, as built"). Its crate is not folded into the Rust archive
the package-set build generates from a set: it declares no
`editorRustCrate`, so an editor of a set that holds echo links the core's
archive, or the one of the set's other crates.

Its lakefile is Lean and not TOML, as every other fixture's is: a TOML
lakefile cannot declare a target that compiles C, a library's
`moreLinkObjs`, or the target that builds the library.

- `editorLibrary` is the package's library: the one already built in its
  `lib/`, or else the crate's `cdylib` built by Cargo. The core's
  package-set build stages it beside every editor it links, and writes
  where in `<executable>.libraries` (`docs/design/packages.md`, "A
  package's library, staged and loaded, as built").
- `echoGlue.o` is the package's glue, `ffi/glue.c`, compiled against the
  toolchain's `lean.h`, with no path compiled in: `Echo.Real`'s
  initialiser reads the library's staged path from the record beside the
  running executable and hands it to the glue's load. The library is not
  linked, so a rebuilt library needs no relink.
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

/-- The package's library (`docs/packages/writing-a-package.md`, "A native
library"), the target the package-set build stages beside every editor it
links (`editorLibrary`, found by name by the core's `setLibraries`): its
value is the library's absolute path, in one of the two forms a package
may give.

- **Already built.** When the package holds `lib/libecho_service.dylib`
  (`.so` off macOS), a library built ahead, that is the library, and no
  process runs: so a copy of echo outside the repository with its library
  in `lib/` is a third party's package with a prebuilt library, which a
  user's set builds with no compiler of the user's.
- **Built with the user's tooling.** Otherwise the crate's `cdylib`, built
  by Cargo through Lake's `proc` with its own up-to-date check
  (`cargo build --release --locked --lib -p echo-service`) over the
  repository's manifest, into its target directory, which the core's Rust
  builds share. `cargo` is the bare command name, as the core's `buildRust`
  keeps it, so a missing Cargo fails with Lake's own spawn line, which the
  core's staging reports naming echo and cargo. Only the package-set build
  reaches this target, never the package's test driver, so `mise run
  lean-test`'s failing `cargo` never runs it.

Its content is the trace. -/
target editorLibrary pkg : FilePath :=
  Job.async do
    let extension := if Platform.isOSX then "dylib" else "so"
    let name := s!"libecho_service.{extension}"
    let prebuilt := pkg.dir / "lib" / name
    if ← prebuilt.pathExists then
      let library ← IO.FS.realPath prebuilt
      setTrace (← computeTrace library)
      return library
    let root ← IO.FS.realPath (pkg.dir / ".." / ".." / "..")
    let targetDir := root / "target"
    proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["build", "--release", "--locked", "--lib", "-p", "echo-service", "--manifest-path",
              (root / "Cargo.toml").toString, "--target-dir", targetDir.toString] }
    let library := targetDir / "release" / name
    setTrace (← computeTrace library)
    return library

/-- The package's glue (`ffi/glue.c`), compiled against the toolchain's own
`lean.h`. No path is compiled in: the library is the one the package-set
build staged beside the executable, which `Echo.Real`'s initialiser finds
when it runs. Nothing lints C for us, so every warning is an error. -/
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

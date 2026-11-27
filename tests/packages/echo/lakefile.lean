import Lake

open Lake DSL System

/-! A fixture package outside the core that holds Rust (docs/design/packages.md,
"Rust in a package"), used by tests alone: it shows a package shipping its
Rust as a library of its own, loaded by the core when the editor starts,
and the glue that binds it (docs/design/packages.md, "A library loaded when
the editor runs, as built"). Its crate is not folded into the Rust archive
the package-set build generates from a set: it declares no
`editorRustCrate`, so an editor of a set that holds echo links the core's
archive, or the one of the set's other crates.

Its lakefile is Lean and not TOML, as every other fixture's is: a TOML
lakefile cannot declare a target that compiles C, a library's
`moreLinkObjs`, or the target that builds the library.

- `echoLibrary` builds the crate's `cdylib` with Cargo, in the repository's
  workspace and target directory, and gives its absolute path. Phase 4 of
  the roadmap `package-native-libraries` stages it into the install instead.
- `echoGlue.o` is the package's glue, `ffi/glue.c`, compiled against the
  toolchain's `lean.h`, with the library's path compiled in
  (`ECHO_LIBRARY`); its job waits on the library's, so building `EchoReal`,
  and any executable that links it, builds the library first. The library
  is not linked, so a rebuilt library needs no relink.
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

/-- The package's library: the crate's `cdylib`, built by Cargo with its own
up-to-date check (`cargo build --release --locked --lib -p echo-service`)
over the repository's manifest, into its target directory, which the
core's Rust builds share, and its absolute path,
`target/release/libecho_service.dylib` (`.so` off macOS). Its content is
the trace. `cargo` is the bare command name, as the core's `buildRust`
keeps it: only `EchoReal` reaches this target, never the package's test
driver, so `mise run lean-test`'s failing `cargo` never runs it. -/
target echoLibrary pkg : FilePath :=
  Job.async do
    let root ← IO.FS.realPath (pkg.dir / ".." / ".." / "..")
    let targetDir := root / "target"
    proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["build", "--release", "--locked", "--lib", "-p", "echo-service", "--manifest-path",
              (root / "Cargo.toml").toString, "--target-dir", targetDir.toString] }
    let extension := if Platform.isOSX then "dylib" else "so"
    let library := targetDir / "release" / s!"libecho_service.{extension}"
    setTrace (← computeTrace library)
    return library

/-- `text` as a C string literal: quoted, with each backslash and quote
escaped. -/
def cString (text : String) : String :=
  "\"" ++ (text.replace "\\" "\\\\").replace "\"" "\\\"" ++ "\""

#guard cString "/r/target/release/libecho_service.so" == "\"/r/target/release/libecho_service.so\""

#guard cString "/a \"b\"\\c" == "\"/a \\\"b\\\"\\\\c\""

/-- The package's glue (`ffi/glue.c`), compiled against the toolchain's own
`lean.h`, with the library's path (`echoLibrary`) compiled in as
`ECHO_LIBRARY`. Nothing lints C for us, so every warning is an error. -/
target echoGlue.o pkg : FilePath := do
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  let libraryJob ← echoLibrary.fetch
  libraryJob.bindM fun library =>
      buildLeanO (pkg.buildDir / "ffi" / "glue.o") srcJob #[]
        #["-O2", "-Wall", "-Wextra", "-Werror", s!"-DECHO_LIBRARY={cString library.toString}"]

/-- The port, its model, its contract and the entry module: every module of
the package but its tests and the binding. -/
@[default_target] lean_lib Echo where
  globs :=
  #[.one `Echo, .one `Echo.Model, .one `Echo.Contract, .one `Echo.Checksum, .one `Echo.Job,
    .one `Echo.Library, .one `Echo.Packages, .one `Echo.EditorPackage]
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

import Lake

open Lake DSL System

/-- The editor's Lean package.

Every Lean linter is on, and a warning fails the build, so `lake build` is
also the lint gate (the Lean counterpart of `cargo clippy -- -D warnings`).
Silence a linter for one declaration with `set_option linter.<name> false in`. -/
package editor where leanOptions := #[⟨`linter.all, true⟩, ⟨`warningAsError, true⟩]

/-- The Lean formatter (`mise run lean-fmt`, `mise run lean-format`). Its
releases are tagged with the Lean toolchain they are built for, so bump
this together with `lean-toolchain`. -/
require «lean-fmt» from git "https://github.com/jcreinhold/lean-fmt"@"v4.35.0"

/-- One library holding both the user-facing prelude (`Editor`, imported by
user config at runtime) and the embedding API (`EditorHost`, the config
session). -/
@[default_target] lean_lib Editor where roots := #[`Editor, `EditorHost]

/-- The Rust static library (`crates/editor-ffi`). Cargo does its own
up-to-date check, so it runs on every `lake build`. The archive's content hash
is the trace, so the executables relink only when the archive changed.

The target directory is passed explicitly, so a `CARGO_TARGET_DIR` in the
environment cannot make Cargo write the archive somewhere else. -/
target rustlib pkg : FilePath :=
  Job.async do
    let root := pkg.dir / ".."
    let targetDir := root / "target"
    proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["build", "--release", "--locked", "--package", "editor-ffi", "--manifest-path",
              (root / "Cargo.toml").toString, "--target-dir", targetDir.toString] }
    let lib := targetDir / "release" / "libeditor_ffi.a"
    setTrace (← computeTrace lib)
    return lib

/-- The directory of the static libraries Lean's runtime needs (libgmp, libuv
and the rest), inside the Lean toolchain Lake itself is using. -/
def leanSystemLibDir : FilePath :=
  run_io
    do
      let some lean ←
        findLeanInstall? | throw <| IO.userError "cannot find the Lean toolchain to link against"
      return lean.systemLibDir

/-- The link arguments both executables need beyond their objects.

`-L`: with `LEAN_CC` set (see the `lean` task in `mise.toml`), Lake no longer
adds the toolchain's own library directory to the link.

The system libraries the Rust archive needs come from
`cargo rustc -p editor-ffi --release --lib --crate-type staticlib -- --print native-static-libs`.
Today that is `-lSystem -lc -lm`, which the system compiler links anyway, so
nothing is listed. The frameworks a window needs are added here with the crate
that needs them. -/
def linkArgs : Array String :=
  #["-L", leanSystemLibDir.toString]

/-- The editor. `supportInterpreter` exports the executable's symbols, so
interpreted config can find compiled definitions and `@[extern]` symbols. -/
@[default_target] lean_exe editor where
  root := `Main
  supportInterpreter := true
  moreLinkObjs := #[rustlib]
  moreLinkArgs := linkArgs

/-- The checks of the boundary with the Rust library (`FfiTest.lean`), linked
exactly like `editor`. `mise run ffi-test` runs it. -/
@[default_target] lean_exe «ffi-test» where
  root := `FfiTest
  supportInterpreter := true
  moreLinkObjs := #[rustlib]
  moreLinkArgs := linkArgs

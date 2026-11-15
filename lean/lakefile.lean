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

/-- The editor's modules. Its root, `Editor`, is what user config is elaborated
on at runtime, and the build makes its `.olean` files for that. The modules
under `Editor/` that `Editor` does not import (the bindings, the real
bindings of the ports, the config session, the headless mode) are built for
the executables that import them. -/
@[default_target] lean_lib Editor where roots := #[`Editor]

/-- Code that `ffi-test overflow` has Lean's interpreter run
(`InterpretedFixture.lean`; `mise run ffi-overflow`). It is a library of its
own that no executable imports, so it is compiled to an `.olean` and never
linked. -/
@[default_target] lean_lib InterpretedFixture

/-- A module with state of its own (`ConfigFixture.lean`), for the check that
compiled code and config share one copy of a module's globals. `config-test`
imports it, so it is linked into that executable, and the same executable
imports its `.olean` again at runtime as part of the base config is
elaborated on. -/
lean_lib ConfigFixture

/-- Whether the build is for Linux, read from the target triple of the Lean
toolchain Lake runs on (`aarch64-unknown-linux-gnu`): `System.Platform` has a
flag for macOS and for Windows and none for Linux. -/
def isLinux : Bool :=
  (Platform.target.splitOn "linux").length > 1

/-- Fails the build with a reason anywhere but macOS and Linux. The entry
point, its link flag, the glue's stack-size readout and the Rust library's
main-thread check each have a case for those two. Windows needs a third of
each (`docs/design/lean-runtime.md`, "Build"). -/
def requireSupportedPlatform : JobM Unit := do
  unless Platform.isOSX || isLinux do
    error
        "the editor executables build only on macOS and Linux; see `requireSupportedPlatform` in lakefile.lean"

/-- The Rust static library (`crates/editor-ffi`). Cargo does its own
up-to-date check, so it runs on every `lake build`. The archive's content hash
is the trace, so the executables relink only when the archive changed.

The target directory is passed explicitly, so a `CARGO_TARGET_DIR` in the
environment cannot make Cargo write the archive somewhere else.

`cargo` is found through the `PATH`, and `mise run lean-test` relies on that:
it puts a `cargo` that always fails first on the `PATH` (`no-cargo/cargo`) to
show that the model tests build without this target. Keep it a bare command
name, or that task shows nothing. -/
target rustlib pkg : FilePath :=
  Job.async do
    requireSupportedPlatform
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

/-- The C glue between `@[extern]` declarations and the Rust library
(`ffi/glue.c`), compiled against the toolchain's own `lean.h`. Nothing lints C
for us, so every warning is an error. -/
target glue.o pkg : FilePath := do
  requireSupportedPlatform
  let oFile := pkg.buildDir / "ffi" / "glue.o"
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  buildLeanO oFile srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

/-- The directory of the static libraries Lean's runtime needs (libgmp, libuv
and the rest), inside the Lean toolchain Lake itself is using. -/
def leanSystemLibDir : FilePath :=
  run_io
    do
      let some lean ←
        findLeanInstall? | throw <| IO.userError "cannot find the Lean toolchain to link against"
      return lean.systemLibDir

/-- The link arguments every executable linked with the Rust library needs
beyond its objects.

The entry point: `editor_entry` (`ffi/glue.c`) runs in place of `main`. It
keeps the process's main thread for the Rust library and runs Lean's
generated `main` on a second thread. On macOS `-Wl,-e` makes it the entry
point. On Linux `-e` would replace `_start` and skip the C library's
start-up, so `-Wl,--wrap=main` renames instead: the start-up code's `main`
becomes the glue's `__wrap_main`, which calls `editor_entry`, and Lean's
`main` becomes `__real_main`. GNU ld and lld both have `--wrap`.

`-L`: with `LEAN_CC` set (see the `lean` task in `mise.toml`), Lake no longer
adds the toolchain's own library directory to the link.

The system libraries the Rust archive needs come from
`cargo rustc -p editor-ffi --release --lib --crate-type staticlib -- --print native-static-libs`.
On macOS that is the frameworks and the two libraries listed here, beside
`-lSystem -lc -lm`, which the system compiler links anyway: the window
library (winit, in `editor-platform-winit`) brings the first seven and the
two libraries; the renderer (wgpu, in `editor-render-wgpu`) brings `Metal`
and `QuartzCore`; and the shaper's font library (fontique, in
`editor-shape-parley`) brings `CoreText` (the display pipeline's phase 6,
which linked both into the archive). On Linux it is
`-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc`, all of which the link has
already, so nothing is listed: winit loads the display's libraries when it
runs, and wgpu its graphics driver. Run that command again when a crate
with system dependencies is added. -/
def linkArgs : Array String :=
  #["-L", leanSystemLibDir.toString] ++
    if Platform.isOSX then
      #["-Wl,-e,_editor_entry", "-framework", "ApplicationServices", "-framework", "CoreGraphics",
        "-framework", "CoreVideo", "-framework", "Carbon", "-framework", "CoreFoundation",
        "-framework", "AppKit", "-framework", "Foundation", "-framework", "Metal", "-framework",
        "QuartzCore", "-framework", "CoreText", "-liconv", "-lobjc"]
    else #["-Wl,--wrap=main"]

/-- The editor. `supportInterpreter` exports the executable's symbols, so
interpreted config can find compiled definitions and `@[extern]` symbols. It
imports the config session, so Lean's elaborator is linked in. -/
@[default_target] lean_exe editor where
  root := `Main
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs

/-- The checks of the boundary with the Rust library (`FfiTest.lean`), linked
exactly like `editor`. `mise run ffi-test` runs it. -/
@[default_target] lean_exe «ffi-test» where
  root := `FfiTest
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs

/-- The checks of the config session against the real elaborator
(`ConfigTest.lean`), linked exactly like `editor`. `mise run ffi-test` runs
it. It also holds the benchmark `mise run config-bench` runs. -/
@[default_target] lean_exe «config-test» where
  root := `ConfigTest
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs

/-- The model tests (`ModelTest.lean`): `lake test` builds and runs this
(`mise run lean-test`). It is not a default target and links no glue and no
Rust archive, so nothing it needs reaches `rustlib`. `-L`: as in `linkArgs`,
so it links under either compiler. It starts at Lean's `main`. -/
@[test_driver] lean_exe «model-test» where
  root := `ModelTest
  moreLinkArgs := #["-L", leanSystemLibDir.toString]

/-- The contract checks of the text port and of the job port against their
real bindings (`ContractTest.lean`), linked like `editor` with the glue and
the Rust archive. `mise run ffi-test` runs it. It interprets nothing, so it
does not export its symbols. -/
@[default_target] lean_exe «contract-test» where
  root := `ContractTest
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs

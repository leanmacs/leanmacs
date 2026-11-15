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

/-- Whether the build is for macOS on arm64, read from the target triple of
the Lean toolchain Lake runs on (`arm64-apple-darwin24.6.0`). -/
def isArm64Mac : Bool :=
  Platform.isOSX && (Platform.target.startsWith "arm64-" || Platform.target.startsWith "aarch64-")

/-- Fails the build with a reason anywhere but macOS on arm64: the app
bundle is built and checked there only (`LSArchitecturePriority`, `lipo`,
`codesign`). -/
def requireArm64Mac : JobM Unit := do
  unless isArm64Mac do
    error
        s!"the app bundle builds only on macOS on arm64 (this toolchain targets {Platform.target}); see `requireArm64Mac` in lakefile.lean"

/-- The app's name: the bundle's, `<name>.app`, and its icon's. -/
def appName : String :=
  "Leanmacs"

/-- The bundle identifier. The repository is leanmacs/leanmacs. -/
def appIdentifier : String :=
  "io.github.leanmacs.Leanmacs"

/-- The lowest macOS the bundle has been run on (27.2, 2026-11-15); lower it
only after running it there. -/
def appMinimumSystemVersion : String :=
  "27.2"

/-- The bundle's `Contents/Info.plist`. There are no document types (the
roadmap's phase 5 adds them) and no version keys, since the project has no
version scheme yet. -/
def appInfoPlist : String :=
  s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>editor</string>
\t<key>CFBundleIconFile</key>
\t<string>{appName}</string>
\t<key>CFBundleIdentifier</key>
\t<string>{appIdentifier}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>{appName}</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
\t<key>LSArchitecturePriority</key>
\t<array>
\t\t<string>arm64</string>
\t</array>
\t<key>LSMinimumSystemVersion</key>
\t<string>{appMinimumSystemVersion}</string>
\t<key>NSHighResolutionCapable</key>
\t<true/>
</dict>
</plist>
"

/-- `n` as four bytes, the most significant first, as ICNS writes its
lengths. -/
def bigEndian32 (n : Nat) : ByteArray :=
  ⟨#[(n / 16777216 % 256).toUInt8, (n / 65536 % 256).toUInt8, (n / 256 % 256).toUInt8,
      (n % 256).toUInt8]⟩

/-- An ICNS entry: its four-byte type, its length with its eight-byte
header, and its data. -/
def icnsEntry (type : String) (data : ByteArray) : ByteArray :=
  type.toUTF8 ++ bigEndian32 (8 + data.size) ++ data

/-- The placeholder icon, `Contents/Resources/Leanmacs.icns`, which the
target writes and nothing checks in: a minimal ICNS of one 16×16 image in
one flat colour. Its `is32` entry holds the red, green and blue channels
one after the other, each 256 bytes run-length encoded as two runs (a byte
of 0x80 + n − 3 repeats the next byte n times: 130, then 126), and its
`s8mk` entry is the mask, 256 bytes of 0xFF. `mise run app-check` reads it
with ImageIO (`sips`). -/
def appIcon : ByteArray :=
  let channel (value : UInt8) : ByteArray := ⟨#[0xFF, value, 0xFB, value]⟩
  let entries :=
    icnsEntry "is32" (channel 0x3A ++ channel 0x6E ++ channel 0xA5) ++
      icnsEntry "s8mk" ⟨Array.replicate 256 0xFF⟩
  "icns".toUTF8 ++ bigEndian32 (8 + entries.size) ++ entries

/-- `Leanmacs.app`, the editor as a macOS app bundle, at
`.lake/build/Leanmacs.app` (`mise run app`; `docs/dev-practices/building.md`,
"The app bundle"). It is not a default target: the gate never builds it, and
it is refused with the reason anywhere but macOS on arm64
(`requireArm64Mac`).

It holds `Contents/MacOS/editor`, a copy of the `editor` executable; under
`Contents/Resources/lean`, the `.olean`, `.olean.server` and
`.olean.private` files of the modules `Editor` imports (the closure
`config-test bench-modules` lists), from the toolchain Lake runs on, which
is the pinned one, and from this package, laid out by
`tools/stage-bundle.sh` as `bundle-test` lays them out; `Contents/Info.plist`
(`appInfoPlist`); and `Contents/Resources/Leanmacs.icns` (`appIcon`).

The bundle is signed again as a whole, ad-hoc, and last: the linker's
ad-hoc signature covers only the Mach-O, so `Info.plist` and the resources
would be left unsealed, and any write after signing breaks the seal.
Extended attributes are cleared first, since `codesign --verify --strict`
refuses them.

The trace mixes the executable's, `config-test`'s, the library's, the stage
script's and this lakefile's traces with the toolchain's, the platform's,
the property list's and the icon's, so the bundle is rebuilt, from nothing,
only when one of them changed, or when the bundle is gone. The lakefile is
in it because it is the recipe: without it, a change to how the bundle is
made would leave the old bundle standing. -/
target editorApp pkg : FilePath := do
  requireArm64Mac
  let exe ← editor.fetch
  let lister ← «config-test».fetch
  let library ← Editor.fetch
  let stager ← inputTextFile <| pkg.dir / ".." / "tools" / "stage-bundle.sh"
  -- This file is the recipe, so a change to it rebuilds the bundle too.
  let recipe ← inputTextFile <| pkg.dir / "lakefile.lean"
  let inputs :=
    (((exe.zipWith Prod.mk lister).zipWith Prod.mk stager).zipWith (fun paths _ => paths)
          library).zipWith
      (fun paths _ => paths) recipe
  inputs.mapM fun ((exe, lister), stager) => do
      addLeanTrace
      addPlatformTrace
      addTrace (.ofHash (pureHash appInfoPlist) "Info.plist")
      addTrace (.ofHash (Hash.ofByteArray appIcon) s!"{appName}.icns")
      let bundle := pkg.buildDir / s!"{appName}.app"
      let traceFile := pkg.buildDir / s!"{appName}.app.trace"
      buildUnlessUpToDate bundle (← getTrace) traceFile do
          -- A rebuild starts from nothing, so it never keeps a stale module.
          if ← bundle.pathExists then
            IO.FS.removeDirAll bundle
          let sysroot ← getLeanSysroot
          let closure := pkg.buildDir / s!"{appName}.app.closure"
          let modules ←
            captureProc
                { cmd := lister.toString
                  args := #["bench-modules", sysroot.toString, pkg.leanLibDir.toString, "Editor"] }
          IO.FS.writeFile closure (modules ++ "\n")
          proc (quiet := true)
              { cmd := stager.toString
                args :=
                  #["--closure", closure.toString, bundle.toString, exe.toString, sysroot.toString,
                    pkg.leanLibDir.toString, "olean", "olean.server", "olean.private"] }
          IO.FS.writeFile (bundle / "Contents" / "Info.plist") appInfoPlist
          IO.FS.writeBinFile (bundle / "Contents" / "Resources" / s!"{appName}.icns") appIcon
          -- The system's tools, by absolute path: mise's PATH may hold others of
          -- the same name (a Python package installs an `xattr` with no `-r`).
          proc (quiet := true) { cmd := "/usr/bin/xattr", args := #["-cr", bundle.toString] }
          -- Last: nothing may be written into the bundle after this.
          proc (quiet := true)
              { cmd := "/usr/bin/codesign", args := #["--force", "--sign", "-", bundle.toString] }
      return bundle

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

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

/-- The lowest macOS the bundle has been run on; lower it only after running
it there. The window was run by hand on 27.2 (2026-11-15). The owner chose
26.0 on 2026-11-17: CI's `mise run app-check` runs the shipped bundle's
headless mode on the `macos-26` runner on every main build, and the owner
checks once that the nightly opens its window on a macOS 26 Mac
(docs/dev-practices/ci.md, "Deployment target"). It must equal
`MACOSX_DEPLOYMENT_TARGET` in mise.toml. -/
def appMinimumSystemVersion : String :=
  "26.0"

/-- The app's version file, relative to the package's directory: one line,
the version, which `editorApp` writes into `Info.plist`. -/
def appVersionFile : FilePath :=
  "app" / "version"

/-- The icon's artwork, relative to the package's directory: a 1024×1024
PNG, from which `editorApp` makes `Contents/Resources/Leanmacs.icns`. -/
def appIconFile : FilePath :=
  "app" / "Leanmacs.png"

/-- The version in the contents of the version file (`appVersionFile`): its
one line, less one trailing newline, which must be one to three
dot-separated runs of ASCII digits, the form `CFBundleShortVersionString`
takes. Anything else, a second line, whitespace or
an empty file among it, is an error naming the file and what it holds, so a
malformed version fails the build instead of making a bundle LaunchServices
misreads (`mise run app-check`, step 10). -/
def parseAppVersion (contents : String) : Except String String :=
  let line := if contents.endsWith "\n" then (contents.dropEnd 1).toString else contents
  let parts := line.splitOn "."
  let isRun (part : String) : Bool := !part.isEmpty && part.all Char.isDigit
  if parts.length ≤ 3 && parts.all isRun then .ok line
  else
    .error
      s!"{appVersionFile} must be one line of one to three dot-separated runs of digits, such as 0.1.0, but holds {repr contents}"

/-- The variable `editorApp` takes the build ID from, which it writes as
`CFBundleVersion`. `mise run app` sets it from `leanmacs-release build-id`
(crates/editor-release), and CI from its run's `build-id` job. -/
def appBuildIdVar : String :=
  "LEANMACS_BUILD_ID"

/-- The variable `editorApp` takes the commit from, which it writes as
`LeanmacsCommit`. `mise run app` sets it from `leanmacs-release commit`, and
CI from `github.sha`. -/
def appCommitVar : String :=
  "LEANMACS_COMMIT"

/-- The build ID and the commit, from the values of `appBuildIdVar` and
`appCommitVar`: each must be set, the build ID to 14 ASCII digits and the
commit to 40 lowercase hex digits. Anything else is an error naming the
variable and what it holds, so a build without its stamp fails instead of
making a bundle that names no build. Only the shape is checked here, which
keeps the plist well-formed; whether the digits name a valid time is
`editor-release`'s to check, and `leanmacs-release` checks it before it
sets the variable (`mise run app-check`, step 14). -/
def parseAppStamp (buildId commit : Option String) : Except String (String × String) := do
  let hint := "`mise run app` sets both from HEAD, and CI from its run"
  let shown : Option String → String
    | some value => s!"holds {repr value}"
    | none => "is unset"
  let isHex (c : Char) : Bool := c.isDigit || ('a' ≤ c && c ≤ 'f')
  let build ←
    match buildId with
    | some id =>
      if id.length == 14 && id.all Char.isDigit then
        pure id
      else
        throw
            s!"{appBuildIdVar} must be the build ID, 14 digits (YYYYMMDDHHMMSS, UTC), but {shown buildId}; {hint}"
    | none =>
      throw
          s!"{appBuildIdVar} must be the build ID, 14 digits (YYYYMMDDHHMMSS, UTC), but is unset; {hint}"
  let sha ←
    match commit with
    | some sha =>
      if sha.length == 40 && sha.all isHex then
        pure sha
      else
        throw
            s!"{appCommitVar} must be the commit, 40 lowercase hex digits, but {shown commit}; {hint}"
    | none =>
      throw s!"{appCommitVar} must be the commit, 40 lowercase hex digits, but is unset; {hint}"
  return (build, sha)

/-- Whether the artwork (`appIconFile`) is a 1024×1024 PNG, from what
`/usr/bin/sips -g pixelWidth -g pixelHeight -g format` prints for it: a
line `  <key>: <value>` for each. Anything else is an error naming the file
and what `sips` read, so artwork of another size or format fails the build
instead of being stretched into a blurred icon (`mise run app-check`,
step 12). -/
def checkAppArtwork (sipsOutput : String) : Except String Unit :=
  let field (key : String) : String :=
    let pre := s!"  {key}: "
    match (sipsOutput.splitOn "\n").find? (·.startsWith pre) with
    | some line => (line.drop pre.length).toString
    | none => "nothing"
  let (width, height, format) := (field "pixelWidth", field "pixelHeight", field "format")
  if width == "1024" && height == "1024" && format == "png" then .ok ()
  else
    .error s!"{appIconFile} must be a 1024x1024 PNG, but sips reads it as {width}x{height} {format}"

/-- The bundle's `Contents/Info.plist`, for the app at `version`, the line
of the version file (`appVersionFile`), built as `build` from `commit`
(`parseAppStamp`). The version is `CFBundleShortVersionString`, the build ID
`CFBundleVersion`, and the commit `LeanmacsCommit`, a key of the app's own
with no dot in it, so `plutil -extract` can address it. `editor --version`
reads the three (`Editor/Version.lean`, `plistKeys`). `NSHumanReadableCopyright` names
the licence, as `Cargo.toml` gives it, and `LSApplicationCategoryType` files
the app under developer tools.

The rule for its document types (`CFBundleDocumentTypes`): registered for
text, default for nothing. The app's role is `Editor` for each, since it
reads and writes them, and no `LSHandlerRank` is `Owner` or `Default`, the
ranks that let LaunchServices make an app the default for a type.

- "Text" is `public.text`, the type plain text, source code, JSON, XML and
  YAML conform to, at rank `Alternate`: Finder lists the app under "Open
  With" for all of them, and never chooses it over an `Owner` or `Default`
  app.
- "Any file" is `public.data` at rank `None`, which Apple defines as never
  selected to open files of the type but accepting drops of them. So a file
  of a type the system does not know (`.lean`, a file with no extension,
  which get a dynamic type conforming only to `public.data`) can be dropped
  on the Dock icon or opened through "Open With > Other…", and the app is
  not listed in every file's "Open With" menu. If it ever is, this entry is
  dropped.

The app declares no type of its own and none on another's behalf (no
`UTExportedTypeDeclarations` or `UTImportedTypeDeclarations`). -/
def appInfoPlist (version build commit : String) : String :=
  s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
\t<key>CFBundleDocumentTypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>CFBundleTypeName</key>
\t\t\t<string>Text</string>
\t\t\t<key>CFBundleTypeRole</key>
\t\t\t<string>Editor</string>
\t\t\t<key>LSHandlerRank</key>
\t\t\t<string>Alternate</string>
\t\t\t<key>LSItemContentTypes</key>
\t\t\t<array>
\t\t\t\t<string>public.text</string>
\t\t\t</array>
\t\t</dict>
\t\t<dict>
\t\t\t<key>CFBundleTypeName</key>
\t\t\t<string>Any file</string>
\t\t\t<key>CFBundleTypeRole</key>
\t\t\t<string>Editor</string>
\t\t\t<key>LSHandlerRank</key>
\t\t\t<string>None</string>
\t\t\t<key>LSItemContentTypes</key>
\t\t\t<array>
\t\t\t\t<string>public.data</string>
\t\t\t</array>
\t\t</dict>
\t</array>
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
\t<key>CFBundleShortVersionString</key>
\t<string>{version}</string>
\t<key>CFBundleVersion</key>
\t<string>{build}</string>
\t<key>LSApplicationCategoryType</key>
\t<string>public.app-category.developer-tools</string>
\t<key>LSArchitecturePriority</key>
\t<array>
\t\t<string>arm64</string>
\t</array>
\t<key>LSMinimumSystemVersion</key>
\t<string>{appMinimumSystemVersion}</string>
\t<key>LeanmacsCommit</key>
\t<string>{commit}</string>
\t<key>NSHighResolutionCapable</key>
\t<true/>
\t<key>NSHumanReadableCopyright</key>
\t<string>Licensed under GPL-3.0-or-later.</string>
</dict>
</plist>
"

/-- The images of the icon's `.iconset`, each with its size in pixels: the
ten standard ones, 16, 32, 128, 256 and 512 points at 1× and 2×.
`editorApp` makes each from the artwork (`appIconFile`) with `sips`, and
`mise run app-check` finds exactly these in the built icon. -/
def appIconSizes : List (String × Nat) :=
  [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)]

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
(`appInfoPlist`), with the version from `app/version` (`appVersionFile`,
`parseAppVersion`, which fails the build on a malformed line) and the build
ID and the commit from `LEANMACS_BUILD_ID` and `LEANMACS_COMMIT`
(`parseAppStamp`, which fails the build when either is unset or
malformed; `mise run app` sets both); and
`Contents/Resources/Leanmacs.icns`, made from the artwork `app/Leanmacs.png`
(`appIconFile`, which `checkAppArtwork` requires to be a 1024×1024 PNG) by
`sips` into the ten images of `appIconSizes` and then
`iconutil`.

The bundle is signed again as a whole, ad-hoc, and last: the linker's
ad-hoc signature covers only the Mach-O, so `Info.plist` and the resources
would be left unsealed, and any write after signing breaks the seal.
Extended attributes are cleared first, since `codesign --verify --strict`
refuses them.

The trace mixes the executable's, `config-test`'s, the library's, the stage
script's, this lakefile's, the version file's and the artwork's traces with
the toolchain's, the platform's and the property list's, so the bundle is rebuilt, from nothing,
only when one of them changed, or when the bundle is gone. The property
list's trace is a hash of its text, which holds the build ID and the
commit, so a new commit rebuilds and re-signs the bundle. The lakefile is
in it because it is the recipe: without it, a change to how the bundle is
made would leave the old bundle standing. A rebuild assembles and signs the
bundle in `Leanmacs.app.staging` and only then renames it into place, since
Lake keeps the old trace when a build fails: a rebuild that fails or is
interrupted leaves the old bundle, never a half-built one the old trace
would take as up to date (`mise run app-check`, step 7). -/
target editorApp pkg : FilePath := do
  requireArm64Mac
  let exe ← editor.fetch
  let lister ← «config-test».fetch
  let library ← Editor.fetch
  let stager ← inputTextFile <| pkg.dir / ".." / "tools" / "stage-bundle.sh"
  -- This file is the recipe, so a change to it rebuilds the bundle too.
  let recipe ← inputTextFile <| pkg.dir / "lakefile.lean"
  let versionJob ← inputTextFile <| pkg.dir / appVersionFile
  let artJob ← inputBinFile <| pkg.dir / appIconFile
  let inputs :=
    ((((((exe.zipWith Prod.mk lister).zipWith Prod.mk stager).zipWith (fun paths _ => paths)
                  library).zipWith
              (fun paths _ => paths) recipe).zipWith
          Prod.mk versionJob).zipWith
      Prod.mk artJob)
  inputs.mapM fun ((((exe, lister), stager), versionFile), art) => do
      addLeanTrace
      addPlatformTrace
      let version ←
        match parseAppVersion (← IO.FS.readFile versionFile) with
        | .ok version =>
          pure version
        | .error message =>
          error message
      -- The stamp, checked before anything is built, as the version is.
      let (build, commit) ←
        match parseAppStamp (← IO.getEnv appBuildIdVar) (← IO.getEnv appCommitVar) with
        | .ok stamp =>
          pure stamp
        | .error message =>
          error message
      -- Checked before anything is built, as the version is: `sips -z`
      -- below would stretch artwork of any other size without a word.
      let artInfo ←
        captureProc
            { cmd := "/usr/bin/sips"
              args := #["-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", art.toString] }
      match checkAppArtwork artInfo with
      | .ok () =>
        pure ()
      | .error message =>
        error message
      let plist := appInfoPlist version build commit
      addTrace (.ofHash (pureHash plist) "Info.plist")
      let bundle := pkg.buildDir / s!"{appName}.app"
      let traceFile := pkg.buildDir / s!"{appName}.app.trace"
      buildUnlessUpToDate bundle (← getTrace) traceFile do
          -- Assembled beside the bundle and moved into its place only once
          -- signed. Lake writes the trace only when the build succeeds, so a
          -- rebuild that fails or is interrupted must leave the old bundle,
          -- which the old trace describes, never a half-built one under its name.
          let staging := pkg.buildDir / s!"{appName}.app.staging"
          let staged := staging / s!"{appName}.app"
          let old := pkg.buildDir / s!"{appName}.app.old"
          -- A rebuild starts from nothing, so it never keeps a stale module.
          if ← staging.pathExists then
            IO.FS.removeDirAll staging
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
                  #["--closure", closure.toString, staged.toString, exe.toString, sysroot.toString,
                    pkg.leanLibDir.toString, "olean", "olean.server", "olean.private"] }
          IO.FS.writeFile (staged / "Contents" / "Info.plist") plist
          -- The system's tools, by absolute path: mise's PATH may hold others of
          -- the same name (a Python package installs an `xattr` with no `-r`).
          -- The iconset is in the staging directory but outside the bundle, so
          -- it is never sealed and goes with the staging directory.
          let iconset := staging / s!"{appName}.iconset"
          IO.FS.createDirAll iconset
          for (name, size) in appIconSizes do
            proc (quiet := true)
                { cmd := "/usr/bin/sips"
                  args :=
                    #["-z", toString size, toString size, art.toString, "--out",
                      (iconset / name).toString] }
          proc (quiet := true)
              { cmd := "/usr/bin/iconutil"
                args :=
                  #["-c", "icns", iconset.toString, "-o",
                    (staged / "Contents" / "Resources" / s!"{appName}.icns").toString] }
          proc (quiet := true) { cmd := "/usr/bin/xattr", args := #["-cr", staged.toString] }
          -- Last: nothing may be written into the bundle after this.
          proc (quiet := true)
              { cmd := "/usr/bin/codesign", args := #["--force", "--sign", "-", staged.toString] }
          -- Moved into place by renames: an interruption between them leaves
          -- the old bundle or none, and with none the next build rebuilds.
          if ← old.pathExists then
            IO.FS.removeDirAll old
          if ← bundle.pathExists then
            IO.FS.rename bundle old
          IO.FS.rename staged bundle
          IO.FS.removeDirAll staging
          if ← old.pathExists then
            IO.FS.removeDirAll old
      return bundle

/-- The model tests (`ModelTest.lean`): `lake test` builds and runs this
(`mise run lean-test`). It is not a default target and links no glue and no
Rust archive, so nothing it needs reaches `rustlib`. `-L`: as in `linkArgs`,
so it links under either compiler. It starts at Lean's `main`. -/
@[test_driver] lean_exe «model-test» where
  root := `ModelTest
  moreLinkArgs := #["-L", leanSystemLibDir.toString]

/-- The model tests' modules (`ModelTest/*.lean`), which the `model-test`
executable's root `ModelTest.lean` imports. Lake resolves an import only to
a module of a library, never to one of an executable's, so these need a
library of their own. It is not a default target: `lake test` builds it for
the test driver. `.submodules` takes `ModelTest.X` and not `ModelTest`
itself, so the executable's root belongs to no library. -/
lean_lib ModelTests where globs := #[.submodules `ModelTest]

/-- The contract checks of the text port and of the job port against their
real bindings (`ContractTest.lean`), linked like `editor` with the glue and
the Rust archive. `mise run ffi-test` runs it. It interprets nothing, so it
does not export its symbols. -/
@[default_target] lean_exe «contract-test» where
  root := `ContractTest
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs

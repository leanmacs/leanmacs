import Lake

open Lake DSL System
open Lean (Name)

/-- The core's Lean options: every Lean linter on, and a warning an error.
They are the package's, below, and those of the root module the
package-set build generates in another package (`setRoot`), which is
compiled as the core is. -/
def coreLeanOptions : Array LeanOption :=
  #[⟨`linter.all, true⟩, ⟨`warningAsError, true⟩]

/-- The editor's core, as a Lake package. Its name is what a package set
and a package `require`.

Every Lean linter is on, and a warning fails the build, so `lake build` is
also the lint gate (the Lean counterpart of `cargo clippy -- -D warnings`).
Silence a linter for one declaration with `set_option linter.<name> false in`.

It requires no other package. A package set requires this one by path, and
Lake would fetch every git dependency of it into each set's own
`.lake/packages`, so the Lean formatter is the `require` of a package of
its own, `tools/lean-fmt/lakefile.toml`, which nothing requires
(`docs/design/packages.md`, "The package set and its build").

It declares no keyword: it supplies no input scheme (`schemeKeyword`). The
Vim scheme is the default package `evil`'s (`packages/evil/`), so an editor
built from this package alone refuses to start. -/
package «editor-core» where leanOptions := coreLeanOptions

/-- The build's linters (`Lint.lean`, `Lint/Wait.lean`,
`Lint/RealHost.lean`): the wait linters, which refuse a raw clock read and
an inferred wait outside the modules it is allowed in
(`docs/dev-practices/inferred-waits.md`), and the real-host linter, which
refuses a real host or service outside the wiring set
(`docs/dev-practices/real-thread-checks.md`). They
import `Lean`, which the config base and the model tests must not reach
(`docs/design/overview.md`, "Config is elaborated behind a port, and two
adapters link Lean's frontend"; `.agents/rules/structure.md`, "Core
imports"), so this library is outside `Editor` and no module imports
it: every other library of this package, and every package under
`packages/`, loads it as a Lean plugin (`lintPlugin`). Its own modules load no plugin, which would
be themselves. Its tests are `LintTests`, run by `lint-test`, and the
linters' fixtures in the test roots. Its root is the library's name, as a
plugin's must be: Lake initializes a plugin through
`initialize_<library>`. -/
lean_lib Lint where globs := #[.andSubmodules `Lint]

/-- The shared library of `Lint`, the plugin every library loads
(`lintPlugin`). The plugin is this plain target, not the facet key
`Lint:shared`, because Lake (v4.35.0) resolves a plugin named by a facet
key in an async continuation (`PartialBuildKey.fetchInCoreAux`, `.facet`),
which it does not memoise: each module's setup built its own `Lint:shared`,
and the `Lint` modules were rebuilt concurrently into the same
`.olean`/`.ilean`/`.c` and dylib, so one build could lose a file another
was writing (task `lake-builds-lint-modules-several-times-racing-on-ilean`).
Lake fetches a package target's key synchronously and memoises it, so
every module's plugin is this one job. -/
target lintShared pkg : Dynlib := do
  let some lib := pkg.findLeanLib? `Lint | error "no Lint library"
  lib.shared.fetch

/-- The build's linters as a Lean plugin (`lean --plugin`), which each
library of this package but `Lint` and its tests loads as it elaborates
each of its modules, and each package's lakefile names the same way
(`plugins`): the plugin runs the library's `initialize` declarations,
which register the linters and their options, and the modules it is
loaded for import nothing of it, so the linters reach no import closure.
It names `lintShared`, the target above, with this package's name, so a
package set that requires this package by path loads the same one; every
package's lakefile names it as `@editor-core/lintShared`. That
every library and executable loads it, or imports `Lint`, is a reviewer
rule (`.agents/rules/structure.md`, "Lint plugins"). -/
def lintPlugin : TargetArray Dynlib :=
  #[`@«editor-core»/lintShared]

/-- The editor's modules. Its root `Editor` is what user config is elaborated
on at runtime, and the build makes its `.olean` files for that. Its second
root, `Editor.Core`, is the core's (`Editor/Core.lean`,
`docs/design/packages.md`): it imports every module under `Editor/`,
directly or through another, so the build makes every core module, the
ones `Editor` does not import among them (the bindings, the real bindings
of the ports, the config session, the hosts, the test kit under
`Editor/Test/`). This Lake package lists no package of its own and has no
entry module: every feature is another Lake package's (`packages/`), and a
Lake package with no entry module contributes nothing to a set's root
(`entryModule?`). It is named `editor-core`, not `editor`, because a Lake
package named `p` lists its packages in the module `<P>.EditorPackage`,
and `editor` would put a list at `Editor.EditorPackage`, under the
namespace the core's (`docs/design/packages.md`, "The package set and
its build"; `.agents/rules/structure.md`, "Core imports"). -/
@[default_target] lean_lib Editor where
  roots := #[`Editor, `Editor.Core]
  plugins := lintPlugin

/-- The interface library `files-api` (`FilesApi.lean`): the hooks around a
buffer taking in and writing a file, what files does for others, and the
names others reach. It is in the core's Lake package as its own `lean_lib`,
outside `Editor`, with the layout and names an interface package has, and
a core interface for good: session restore, which stays in the core,
reaches files through it. It imports only the core's API, and its test
library only that, this library and the core's test kit. The interface
libraries the features-as-packages roadmap's phase 5 staged here as it is,
`vc-api` and `project-api`, are interface packages since phase 6
(`packages/vc-api/`, `packages/project-api/`): their last users left the
core, and each moved with a `git mv` and a lakefile, no import line in it
changed. -/
lean_lib FilesApi where plugins := lintPlugin

/-- The test library of `files-api` (`FilesApiTest/`): its fake, the core's
kit's opener with the interface's hooks (`FilesApiTest.Fake`), and its
contract check (`FilesApiTest.Contract`). -/
lean_lib FilesApiTest where
  globs := #[.submodules `FilesApiTest]
  plugins := lintPlugin

/-- The interface library `environment-api` (`EnvironmentApi.lean`): the
extension points a child's environment is built from, a hook of directory
sources and a choice of base by name, and their reading rules. It is in the
core's Lake package as its own `lean_lib`, outside `Editor`, with the
layout and names an interface package has, as `FilesApi` is, and a core
interface for good: the host reads a child's layers through it at every
reload that installs, so the core names no source. It imports only the
core's API, and its test library only that, this library and the core's
test kit. -/
lean_lib EnvironmentApi where plugins := lintPlugin

/-- The test library of `environment-api` (`EnvironmentApiTest/`): its fakes
(`EnvironmentApiTest.Fake`), its contract (`EnvironmentApiTest.Contract`)
and the model rigs the contract runs on (`EnvironmentApiTest.Model`). -/
lean_lib EnvironmentApiTest where
  globs := #[.submodules `EnvironmentApiTest]
  plugins := lintPlugin

/-- Code that `ffi-test overflow` has Lean's interpreter run
(`InterpretedFixture.lean`; `mise run ffi-overflow`). It is a library of its
own that no executable imports, so it is compiled to an `.olean` and never
linked. -/
@[default_target] lean_lib InterpretedFixture where plugins := lintPlugin

/-- A module with state of its own (`ConfigFixture.lean`), for the check that
compiled code and config share one copy of a module's globals. `config-test`
imports it, so it is linked into that executable, and the same executable
imports its `.olean` again at runtime as part of the base config is
elaborated on. -/
lean_lib ConfigFixture where plugins := lintPlugin

/-- An extension point and a compiled package that reads it
(`ExtensionFixture.lean`), for the checks that config elaborated at runtime
registers at a compiled package's extension point. `config-test` imports
it, so it is linked into that executable, and the same executable imports
its `.olean` again at runtime as part of the base config is elaborated
on. -/
lean_lib ExtensionFixture where plugins := lintPlugin

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

/-- Writes `text` to `file`, making its directory, unless the file holds
exactly `text` already: a build with nothing to do writes nothing. -/
def writeIfChanged (file : FilePath) (text : String) : IO Unit := do
  let old ←
    if ← file.pathExists then
      some <$> IO.FS.readFile file
    else
      pure none
  unless old == some text do
    if let some dir := file.parent then
      IO.FS.createDirAll dir
    IO.FS.writeFile file text

/-- The name of the crate generated for the key `key`: `editor-rust`, the
core's, for the one key there is, `core`. Its archive is `lib<name, with `_`
for `-`>.a`. Until phase 5 of `package-native-libraries` a set whose
packages held a crate had a crate of its own, `editor-rust-<key>`; no
package's crate is compiled into an archive now. -/
def rustCrateName (key : String) : String :=
  if key == "core" then "editor-rust" else s!"editor-rust-{key}"

/-- The directory the crate for the key `key` is generated in, under the
repository root `root`: `target/editor-rust/<key>`. -/
def rustDir (root : FilePath) (key : String) : FilePath :=
  root / "target" / "editor-rust" / key

/-- The file in a generated crate's directory that holds the system
libraries its archive needs, as rustc's `--print native-static-libs`
wrote them: one line of link arguments. -/
def systemLibrariesFile (dir : FilePath) : FilePath :=
  dir / "native-static-libs"

/-- Quotes `text` as a TOML basic string. -/
def tomlString (text : String) : String :=
  "\"" ++ (text.replace "\\" "\\\\").replace "\"" "\\\"" ++ "\""

/-- The manifest of the crate `name`, the core's archive: a `staticlib` whose
one dependency is `editor-ffi`, at `ffi`. It is a workspace of its own, so
it builds outside the repository's. -/
def rustManifest (name : String) (ffi : FilePath) : String :=
  s!"# Generated by the core's build (`rustlib` in lean/lakefile.lean). Do not
# edit it: the build writes it again.
[package]
name = {tomlString name}
version = \"0.1.0\"
edition = \"2024\"
publish = false

[lib]
crate-type = [\"staticlib\"]
path = \"lib.rs\"

[workspace]
resolver = \"3\"

[dependencies]
editor-ffi = \{ path = {tomlString ffi.toString} }
"

/-- The library of the generated crate: it re-exports `editor-ffi`, so the
whole of it is linked into its archive. -/
def rustLibrary : String :=
  "//! The core's Rust archive, generated by the core's build (`rustlib` in
//! lean/lakefile.lean): `editor-ffi`. Do not edit it: the build writes it
//! again.

pub use editor_ffi;
"

/-- The cargo-deny config of the generated crate `name` (`mise run ffi-test`
runs cargo-deny with it): in its graph the generated crate is the one crate
allowed to depend on `editor-ffi`, and `editor-release-std`, the release
tooling's adapters, is banned outright. The root `deny.toml` cannot say
this: nothing in the root graph depends on `editor-ffi`, and cargo-deny
bans a crate with no parents under `wrappers = []`. A package's crate is in
no archive's graph: each ships a library of its own, whose edges its own
allow list holds (`mise run deny`). -/
def rustDenyConfig (name : String) : String :=
  s!"# Generated by the core's build (`rustlib` in lean/lakefile.lean), for the
# cargo-deny run of `mise run ffi-test`. Do not edit it: the build writes it
# again.
[bans]
multiple-versions = \"allow\"
deny = [
  \{ crate = \"editor-ffi\", wrappers = [{tomlString name}], reason = \"only the generated crate links editor-ffi: the core's archive is built from it alone\" },
  \{ crate = \"editor-release-std\", reason = \"the release tooling's adapters are no part of the editor\" },
]
"

/-- Writes the crate generated for the core's archive in the repository
`root` (`rustDir`, key `core`), each file only when its text would change,
and gives its directory: `Cargo.toml` (`rustManifest`), `lib.rs`
(`rustLibrary`), the bans `mise run ffi-test`'s cargo-deny holds it to
(`deny.toml`, `rustDenyConfig`), and a `Cargo.lock` seeded from the root's whenever the
root's changes, so the crate builds against the versions the root lock
holds. -/
def writeRustCrate (root : FilePath) : IO FilePath := do
  let dir := rustDir root "core"
  writeIfChanged (dir / "Cargo.toml")
      (rustManifest (rustCrateName "core") (← IO.FS.realPath (root / "crates" / "editor-ffi")))
  writeIfChanged (dir / "lib.rs") rustLibrary
  writeIfChanged (dir / "deny.toml") (rustDenyConfig (rustCrateName "core"))
  let lock ← IO.FS.readFile (root / "Cargo.lock")
  let seed := dir / "root.lock"
  let seeded ←
    if ← seed.pathExists then
      pure (some (← IO.FS.readFile seed))
    else
      pure none
  unless seeded == some lock && (← (dir / "Cargo.lock").pathExists) do
    IO.FS.writeFile (dir / "Cargo.lock") lock
    IO.FS.writeFile seed lock
  return dir

/-- The line of system libraries `line`, as rustc printed it, with each
library and each framework once, where it first appears: rustc names
`-lSystem` once for each crate that links it, and the macOS linker warns of
a library named twice. -/
def distinctLibraries (line : String) : String :=
  let tokens := ((line.split Char.isWhitespace).filter (!·.isEmpty)).toList.map (·.toString)
  let rec items : List String → List String
    | "-framework" :: framework :: rest => s!"-framework {framework}" :: items rest
    | token :: rest => token :: items rest
    | [] => []
  let kept :=
    (items tokens).foldl (fun kept item => if kept.contains item then kept else kept.push item) #[]
  " ".intercalate kept.toList ++ "\n"

/-- Builds the core's archive, the crate generated in the repository `root`
(`writeRustCrate`), and gives its path: `target/release/libeditor_rust.a`,
in the root's target directory, which the workspace's own builds share, so
a dependency is built once whatever needs it. Beside the crate it leaves the system libraries the archive needs
(`systemLibrariesFile`), which rustc prints, and which the link passes
(`linkAsEditor`). The archive's content hash and that line are the trace, so
an executable relinks only when either changed.

First `cargo fetch --locked` over the root's manifest, so the root lock is
checked and every version it names is at hand; then the build, offline,
which resolves to the seeded lock's versions. rustc writes the libraries
only when it runs: when Cargo finds the crate fresh and the file is
missing (`target/editor-rust` was cleaned), the crate is cleaned and built
again.

`cargo` is found through the `PATH`, and `mise run lean-test` relies on that:
it puts a `cargo` that always fails first on the `PATH` (`no-cargo/cargo`) to
show that the model tests build without this. Keep it a bare command name,
or that task shows nothing. The target directory is passed explicitly, so a
`CARGO_TARGET_DIR` in the environment cannot make Cargo write the archive
somewhere else. -/
def buildRust (root : FilePath) : FetchM (Job FilePath) :=
  Job.async do
    requireSupportedPlatform
    let dir ← writeRustCrate root
    let name := rustCrateName "core"
    let targetDir := root / "target"
    let libraries := systemLibrariesFile dir
    proc (quiet := true)
        { cmd := "cargo"
          args := #["fetch", "--locked", "--manifest-path", (root / "Cargo.toml").toString] }
    let manifest := (dir / "Cargo.toml").toString
    let build :=
      proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["rustc", "--release", "--offline", "--lib", "--manifest-path", manifest,
              "--target-dir", targetDir.toString, "--", "--print",
              s!"native-static-libs={libraries}"] }
    build
    unless ← libraries.pathExists do
      proc (quiet := true)
          { cmd := "cargo"
            args :=
              #["clean", "--release", "--offline", "--package", name, "--manifest-path", manifest,
                "--target-dir", targetDir.toString] }
      build
      unless ← libraries.pathExists do
        error s!"cargo built {name} but rustc wrote no {libraries}"
    IO.FS.writeFile libraries (distinctLibraries (← IO.FS.readFile libraries))
    let archive := targetDir / "release" / s!"lib{name.replace "-" "_"}.a"
    setTrace (← computeTrace archive)
    addPureTrace (← IO.FS.readFile libraries) "native-static-libs"
    return archive

/-- The Rust archive of the core: the crate generated with key `core`
(`buildRust`), which holds `editor-ffi`. The core's own executables link it
(`ffi-test`, `config-test`, `contract-test`), and so does every set's
editor (`linkAsEditor`, through `coreArchive`), so they all share one Cargo
build and one archive. A package's Rust is never folded into it: it ships
as a library of its own (`editorLibrary`). -/
target rustlib pkg : FilePath :=
  buildRust (pkg.dir / "..")

/-- The app's launcher (`crates/editor-launch-std`, the binary `leanmacs`):
the bundle's `CFBundleExecutable`, which starts `Contents/MacOS/editor` by
exec (`docs/design/lean-runtime.md`, "The app's identity across an exec").
Built as `rustlib` is, by Cargo with its own up-to-date check, into the
workspace's `target/release`. Only `editorApp` fetches it, so the model
tests' failing `cargo` (`mise run lean-test`) never reaches it. -/
target launcher pkg : FilePath :=
  Job.async do
    requireSupportedPlatform
    let root := pkg.dir / ".."
    let targetDir := root / "target"
    proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["build", "--release", "--locked", "--package", "editor-launch-std", "--bin",
              "leanmacs", "--manifest-path", (root / "Cargo.toml").toString, "--target-dir",
              targetDir.toString] }
    let binary := targetDir / "release" / "leanmacs"
    setTrace (← computeTrace binary)
    return binary

/-- The bundle's stager (`crates/editor-release-std`, the binary
`stage-bundle`, over `editor_release::bundle`), which lays the app bundle out
from what `editorShipped` lists and writes its link stubs. Built as
`launcher` is, by Cargo with its own up-to-date check, into the workspace's
`target/release`, and traced by the binary, so a change to how the bundle
is laid out rebuilds it. Only `editorApp` fetches it, so the model tests'
failing `cargo` (`mise run lean-test`) never reaches it. -/
target stageBundle pkg : FilePath :=
  Job.async do
    requireSupportedPlatform
    let root := pkg.dir / ".."
    let targetDir := root / "target"
    proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["build", "--release", "--locked", "--package", "editor-release-std", "--bin",
              "stage-bundle", "--manifest-path", (root / "Cargo.toml").toString, "--target-dir",
              targetDir.toString] }
    let binary := targetDir / "release" / "stage-bundle"
    setTrace (← computeTrace binary)
    return binary

/-- The C glue between `@[extern]` declarations and the Rust library
(`ffi/glue.c`), compiled against the toolchain's own `lean.h`. Nothing lints C
for us, so every warning is an error. -/
target glue.o pkg : FilePath := do
  requireSupportedPlatform
  let oFile := pkg.buildDir / "ffi" / "glue.o"
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  buildLeanO oFile srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

/-- The directory of the static libraries Lean's runtime needs of the
toolchain install `install` (`leanSystemLibDir`): the install's own,
whatever `lean` is on the `PATH`. -/
def systemLibDirOf (install : LeanInstall) : FilePath :=
  install.systemLibDir

/-- The two places a Lean toolchain install can be looked up, for
`findSystemLibDir` to choose between. -/
structure LeanInstallLookups (m : Type → Type) where
  /-- The install Lake finds for itself (`Lake.findInstall?`), which takes the
  `lean` beside the running `lake` first. -/
  lakes : m (Option LeanInstall)
  /-- The install of the `lean` first on the `PATH` (`lean --print-prefix`,
  `Lake.findLeanCmdInstall?`). -/
  onPath : m (Option LeanInstall)

/-- The directory of the static libraries Lean's runtime needs, of the
install Lake finds for itself (`lookups.lakes`), or why there is none. It
never asks `lookups.onPath`, not even when Lake finds no install: a `lean`
first on the `PATH` may be a user's other Lean, or one that fails. -/
def findSystemLibDir [Monad m] (lookups : LeanInstallLookups m) : m (Except String FilePath) := do
  let some lean ← lookups.lakes | return .error "cannot find the Lean toolchain to link against"
  return .ok (systemLibDirOf lean)

/-- The real `LeanInstallLookups`, over Lake's own lookups. -/
def lakeInstallLookups : LeanInstallLookups BaseIO where
  lakes := return (← Lake.findInstall?).2.1
  onPath := Lake.findLeanCmdInstall?

/-- The directory of the static libraries Lean's runtime needs (libgmp, libuv
and the rest), inside the Lean toolchain Lake itself is using, as this
lakefile is elaborated: for the core's own `lean_exe`s, whose `moreLinkArgs`
are fixed then. It asks Lake as Lake finds its own toolchain
(`findSystemLibDir` over `lakeInstallLookups`), which takes the `lean`
beside the running `lake` first, and never the `PATH`'s: an app bundle's
`lake`, run with no `lean` on the `PATH`, or with a user's other Lean there,
elaborates this lakefile against its own toolchain
(`docs/design/lean-runtime.md`, "Build"). The editor's own link asks the
workspace's toolchain as it runs instead (`editorLinkArgs`). -/
def leanSystemLibDir : FilePath :=
  run_io
    do
      match ← (findSystemLibDir lakeInstallLookups : BaseIO _) with
      | .ok dir =>
        return dir
      | .error message =>
        throw <| IO.userError message

/-- A fake of `LeanInstallLookups` for the guards below: Lake's own install
is `lakes`, the `PATH`'s `lean` is at `/path`, and each lookup asked is
recorded, in order. -/
def recordingLookups (lakes : Option LeanInstall) : LeanInstallLookups (StateM (Array String)) where
  lakes := do
    modify (·.push "lakes")
    return lakes
  onPath := do
    modify (·.push "path")
    return some { sysroot := "/path" }

/- Guards: the static libraries' directory the core's executables link
against is the one of the toolchain install Lake found for itself, and the
`lean` on the `PATH` is never asked, not even when Lake found none. That
Lake finds its install by the running `lake`, not the `PATH`, is Lake's. -/
#guard
  let lakes : LeanInstall := { sysroot := "/lake" }
  let (dir, asked) := (findSystemLibDir (recordingLookups (some lakes))).run #[]
  dir.toOption == some (systemLibDirOf lakes) && asked == #["lakes"]

#guard
  let (dir, asked) := (findSystemLibDir (recordingLookups none)).run #[]
  dir.toOption.isNone && asked == #["lakes"]

/-- The link arguments of `linkArgs`, with the static libraries'
directory `systemLibDir`. -/
def entryArgs (systemLibDir : FilePath) : Array String :=
  #["-L", systemLibDir.toString] ++
    if Platform.isOSX then #["-Wl,-e,_editor_entry"] else #["-Wl,--wrap=main"]

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

No system library is listed here. Those the Rust archive needs (on macOS
the frameworks winit, wgpu and fontique bring, `-liconv` and `-lobjc`; on
Linux `-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc`) are what rustc prints
for the archive the link takes (`--print native-static-libs`, written
beside the generated crate by `buildRust`), and the link passes that line
after these (`linkAsEditor`; the core's executables, `coreSystemLibraries`).
That archive is the core's alone in every set; a package's library is no
part of the link. -/
def linkArgs : Array String :=
  entryArgs leanSystemLibDir

/-- `linkArgs` for a link that runs now: with the static libraries'
directory of the toolchain the workspace builds with
(`getLeanSystemLibDir`), not the one this lakefile was elaborated with, so
a set's editor links against the Lean that compiled it. -/
def editorLinkArgs : FetchM (Array String) :=
  return entryArgs (← getLeanSystemLibDir)

/-- The system libraries the core's own archive needs (`rustlib`), as a
response file the compiler driver reads (`@<file>`; clang and GCC both take
one): the core's executables are `lean_exe`s, whose `moreLinkArgs` cannot
read a build's output. `rustlib` writes the file, and is in their
`moreLinkObjs`, so it is built before they link, and its trace holds the
file's text. -/
def coreSystemLibraries : String :=
  "@" ++ (systemLibrariesFile (rustDir (__dir__ / "..") "core")).toString

/-- The name of the entry module of the Lake package `pkg`: `<P>.EditorPackage`,
`<P>` being the package's name in upper camel case, the name `lake new`
gives its library (`shipped-themes` gives `ShippedThemes.EditorPackage`).
The module declares `packages : Array Editor.Package` in the namespace of
its own name (`docs/design/packages.md`, "The package set and its
build"). -/
def entryModuleName (pkg : Package) : Name :=
  toUpperCamelCase pkg.baseName ++ `EditorPackage

/-- The entry module of `pkg`, when it has one: a library of `pkg` holds a
module of that name (`entryModuleName`) and its source file exists. A
package with none contributes nothing to a set's root. Lake is asked, and no
source is read. -/
def entryModule? (pkg : Package) : IO (Option Module) := do
  match pkg.findModule? (entryModuleName pkg) with
  | some mod =>
    if ← mod.leanFile.pathExists then
      return some mod
    else
      return none
  | none =>
    return none

/-- The packages of a set, in the order their entry modules register
(`setPackages`), on any items with a key and what each requires: `root`
and every package it requires, directly or through
another, each after the packages it requires, and those in the order its
lakefile declares them. So a package registers after every package it
depends on, the core's packages come first, since every package with an
entry module requires the core, and packages that do not depend on each
other register in the order the set's lakefile names them.

Lake's own list (`Workspace.packages`) is not in that order: it holds a
package reached only through another after the package that requires it.
So this walks the `require`s itself, depth first. The walk keeps the names
of the packages it has entered, so a package is visited once and a cycle,
which Lake refuses when it loads the workspace, could not loop here. -/
partial def requireOrder {α : Type} (key : α → Name) (needs : α → Array α) (root : α) : Array α :=
  (visit root (#[], #[])).2
where
  /-- Visits `item` after what it requires: `state` is the keys of the
  items entered so far and the items in order so far. -/
  visit (item : α) (state : Array Name × Array α) : Array Name × Array α :=
    if state.1.contains (key item) then state
    else
      let state :=
        (needs item).foldl (fun state dep => visit dep state) (state.1.push (key item), state.2)
      (state.1, state.2.push item)

/-- `requireOrder` over a table of each package's name and the names it
requires, in its lakefile's order, from the package `root`: the order
`setPackages` gives, on plain names. A name the table does not hold
requires nothing. -/
def requireOrderOf (table : Array (Name × Array Name)) (root : Name) : Array Name :=
  requireOrder id (fun name => ((table.find? (·.1 == name)).map (·.2)).getD #[]) root

/-- The packages of the set `set` (see `requireOrder`), each found in the
workspace by the name its requirer gives it; a name the workspace does not
hold is passed over. -/
def setPackages (ws : Workspace) (set : Package) : Array Package :=
  requireOrder (·.keyName) (fun pkg => pkg.depConfigs.filterMap (ws.findPackageByName? ·.name)) set

/- Guards: the order a set's packages register in (`requireOrderOf`, the walk
`setPackages` makes, over a table of each package's `require`s in its
lakefile's order): a package comes after every package it requires, so the
core first; packages that do not depend on each other keep the order the
requiring lakefile names them in; and a package two others require (a
diamond) is visited once. -/
#guard
  requireOrderOf #[(`set, #[`a, `b]), (`a, #[`core]), (`b, #[`core]), (`core, #[])] `set ==
    #[`core, `a, `b, `set]

#guard
  requireOrderOf #[(`set, #[`b, `a]), (`a, #[`core]), (`b, #[`core]), (`core, #[])] `set ==
    #[`core, `b, `a, `set]

#guard
  requireOrderOf
      #[(`set, #[`a, `b]), (`a, #[`api, `core]), (`b, #[`api]), (`api, #[`core]), (`core, #[])]
      `set ==
    #[`core, `api, `a, `b, `set]

/-- The repository the core is in: the directory above the core's. -/
def repositoryRoot : FetchM FilePath := do
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  return core.dir / ".."

/-- Where the Rust archive of a set's editor comes from
(`docs/design/packages.md`, "Who can build it"). -/
inductive RustSource where
  /-- Built by Cargo: the core's archive (`rustlib`). -/
  | cargo
  /-- The core's archive as it is already built, read and never built: no
  Cargo runs. -/
  | prebuilt
  deriving DecidableEq, Repr

/-- Where the core's archive of a set comes from, given whether the set is
in the repository: a set outside it, a user's, reuses the core's archive
as it is built, so a user's set links with no Cargo (decided 2026-11-20:
the editor never ships Cargo); a set in the repository, the checkout's own,
is built by Cargo, so a change to the core's Rust is built. Every set's
editor links that archive and no other (`linkAsEditor`). -/
def rustSource (inRepository : Bool) : RustSource :=
  if inRepository then .cargo else .prebuilt

#guard rustSource false == .prebuilt

#guard rustSource true == .cargo

/-- Whether the directory `dir` is the directory `root` or under it, both
as paths with their links resolved. -/
def isUnderRoot (root dir : String) : Bool :=
  dir == root || dir.startsWith (root ++ "/")

/-- Whether the directory of `pkg` is inside the repository `root`. -/
def isInRepository (root : FilePath) (pkg : Package) : IO Bool := do
  return isUnderRoot (← IO.FS.realPath root).toString (← IO.FS.realPath pkg.dir).toString

/- Guards: a set is in the repository when its directory, resolved, is the
repository's or under it (`isUnderRoot`, which `isInRepository` and
`rustSource` decide on), and a directory that only starts with the
repository's name is not. -/
#guard isUnderRoot "/r" "/r"

#guard isUnderRoot "/r" "/r/packages"

#guard !isUnderRoot "/r" "/r-other/packages"

#guard !isUnderRoot "/r" "/home/u/set"

/-- The core's archive in the repository `root` and the file of the system
libraries it needs, as Cargo builds them for the core (`rustlib`):
`target/release/libeditor_rust.a` and
`target/editor-rust/core/native-static-libs`. -/
def prebuiltRustFiles (root : FilePath) : FilePath × FilePath :=
  (root / "target" / "release" / s!"lib{(rustCrateName "core").replace "-" "_"}.a",
    systemLibrariesFile (rustDir root "core"))

/- Guards: the core's archive and its system libraries' file in the
repository (`prebuiltRustFiles`), which a user's set reuses and the
bundle ships at `target/` under `lean`. -/
#guard
  prebuiltRustFiles "/r" ==
    (("/r/target/release/libeditor_rust.a" : FilePath),
      ("/r/target/editor-rust/core/native-static-libs" : FilePath))

/-- The core's archive as it is already built, in the repository `root`
(`target/release/libeditor_rust.a`, with its system libraries beside the
generated crate, `target/editor-rust/core/native-static-libs`), read and
never built: no Cargo runs, and nothing is written. Its trace is the
archive's content and the libraries' line, as `buildRust` gives it. With
either missing the build fails, saying so. -/
def prebuiltRust (root : FilePath) : FetchM (Job FilePath) :=
  Job.async do
    let (archive, libraries) := prebuiltRustFiles root
    unless (← archive.pathExists) && (← libraries.pathExists) do
      error
          s!"the core's Rust archive is not built ({archive} and {libraries}): a user's set reuses it and runs no Cargo"
    setTrace (← computeTrace archive)
    addPureTrace (← IO.FS.readFile libraries) "native-static-libs"
    return archive

/-- The core's own archive for the set `pkg`, the one Rust archive its editor
links (`rustSource`): `rustlib`, built by Cargo, for a set in the
repository; the prebuilt one (`prebuiltRust`) for one outside it, a
user's. -/
def coreArchive (pkg : Package) : FetchM (Job FilePath) := do
  let root ← repositoryRoot
  match rustSource (← isInRepository root pkg) with
  | .cargo =>
    rustlib.fetch
  | .prebuilt =>
    prebuiltRust root

/-- The link arguments, one a token, in the file of system libraries
`file` (`systemLibrariesFile`). -/
def systemLibraryArgs (file : FilePath) : IO (Array String) := do
  let text ← IO.FS.readFile file
  return ((text.split Char.isWhitespace).filter (!·.isEmpty)).toArray.map (·.toString)

/-- The directory of the link stubs in the repository `root`:
`<root>/link-stubs`, which the `stage-bundle` binary (`stageBundle`)
writes into an app bundle's `Contents/Resources/lean` from the shipped
editor (`editor_release::stubs`, as the `link-stubs` binary does). -/
def linkStubsDir (root : FilePath) : FilePath :=
  root / "link-stubs"

/-- The link arguments that name the system's libraries from the link stubs
in `stubs`, whose entries are `names` and whose `platform-version` file
holds `version`: the two search paths, then a framework for each
`<name>.framework` and a library for each `lib<name>.tbd`, in order of
their names, then the platform version, `<minos> <sdk>`, so the
executable records the SDK version the shipped editor's own link recorded.
These are the arguments the user-side link was measured with
(`docs/design/lean-runtime.md`, "A link on the user's machine,
measured"). A `platform-version` that is not two words is refused. -/
def stubLinkArgs (stubs : FilePath) (names : Array String) (version : String) :
    Except String (Array String) := do
  let named :=
    (names.qsort (· < ·)).flatMap fun name =>
      if name.endsWith ".framework" then
        #["-framework", (name.dropEnd ".framework".length).toString]
      else
        if name.startsWith "lib" && name.endsWith ".tbd" then
          #[s!"-l{((name.drop 3).dropEnd 4).toString}"]
        else #[]
  let line := ((version.splitOn "\n").headD "").trimAscii.toString
  let [minos, sdk] := line.splitOn " "
    | throw s!"{stubs / "platform-version"} must hold `<minos> <sdk>`, but holds {repr line}"
  return #["-F", stubs.toString, "-L", stubs.toString] ++ named ++
      #[s!"-Wl,-platform_version,macos,{minos},{sdk}"]

#guard
  (stubLinkArgs "/s" #["platform-version", "libobjc.tbd", "AppKit.framework", "libiconv.tbd"]
        "26.0 26.2\n").toOption ==
    some
      #["-F", "/s", "-L", "/s", "-framework", "AppKit", "-liconv", "-lobjc",
        "-Wl,-platform_version,macos,26.0,26.2"]

#guard (stubLinkArgs "/s" #[] "26.0\n").toOption.isNone

/-- Whether the editor's link names the system's libraries from link stubs:
on macOS, when Lake links with the toolchain's own compiler (no `LEAN_CC`),
whose linker finds no framework in an SDK; otherwise it passes the system
libraries the Rust archive needs as rustc printed them. -/
def linksFromStubs (isOSX customCc : Bool) : Bool :=
  isOSX && !customCc

#guard linksFromStubs true false

#guard !linksFromStubs true true

#guard !linksFromStubs false false

/-- The name of the target a package declares its native library with
(`docs/design/packages.md`, "A package's library, staged and loaded, as
built"): a Lake `target` whose value is the library's absolute path, either
a library already in the package (built ahead, or checked in) or one the
target builds with the user's own tooling, run through Lake's `proc`. -/
def libraryTargetName : Name :=
  `editorLibrary

/-- Where a set's build stages the library file `file` of its Lake package
`lake`, under the set's build directory, and where an install copies it,
under its own directory: `libraries/<lake>/<file>`. -/
def stagedLibraryPlace (lake file : String) : FilePath :=
  "libraries" / lake / file

/-- The text of the record `<executable>.libraries` for `entries`, each a
Lake package's name and where its library is staged: one line
`<lake><TAB><library>` each, in order (`Editor/ModuleLookup.lean`, "The
libraries"); nothing for none. -/
def librariesRecordText (entries : Array (String × String)) : String :=
  entries.foldl (fun text (lake, library) => text ++ s!"{lake}\t{library}\n") ""

/-- The libraries record of an install (`editorInstall`) of a set whose Lake
packages' libraries are `entries`, each a Lake package's name and its
library's file name: one relative line `<lake><TAB>libraries/<lake>/<file>`
each (`stagedLibraryPlace`), in order, so the install's directory can be
renamed into place. -/
def installLibrariesRecord (entries : Array (String × String)) : String :=
  librariesRecordText
    (entries.map fun (lake, file) => (lake, (stagedLibraryPlace lake file).toString))

/-- The lines `editorLibraries` answers, read back: each line's Lake package
and staged library, split at its first tab; a line with none is skipped. -/
def stagedLibrariesOf (lines : Array String) : Array (String × FilePath) :=
  lines.filterMap fun line =>
    match line.splitOn "\t" with
    | lake :: library :: rest => some (lake, "\t".intercalate (library :: rest))
    | _ => none

/- Guards: the libraries' places and records (`stagedLibraryPlace`,
`librariesRecordText`, `installLibrariesRecord`, `stagedLibrariesOf`): the
staged place under `libraries/` named after the Lake package; a line per
Lake package that declares a library, its name, a tab and its library;
none for none; an install's lines relative, under its own `libraries/`; and
the facet's lines read back. -/
#guard
  stagedLibraryPlace "echo" "libecho_service.dylib" ==
    ("libraries/echo/libecho_service.dylib" : FilePath)

#guard
  librariesRecordText #[("echo", "/s/.lake/build/libraries/echo/libecho_service.dylib")] ==
    "echo\t/s/.lake/build/libraries/echo/libecho_service.dylib\n"

#guard librariesRecordText #[] == ""

#guard
  installLibrariesRecord #[("echo", "libecho_service.dylib")] ==
    "echo\tlibraries/echo/libecho_service.dylib\n"

#guard
  stagedLibrariesOf #["echo\t/s/libraries/echo/libecho_service.so", "no tab"] ==
    #[("echo", ("/s/libraries/echo/libecho_service.so" : FilePath))]

/-- The tool a library target found missing, and how, from one entry of the
target's log: Lake's process helpers (`proc`, `captureProc`, through
`rawProc`, Lake 4.35.0's `Lake/Util/Proc.lean`) log a spawned program's
standard error as `stderr:` and its text, and Lean's runtime writes
`could not execute external process '<cmd>'` there when the program is not
found; a spawn Lake itself cannot make fails with `failed to execute
'<cmd>': <error>`. None for any other entry. -/
def libraryToolMissing? (entry : String) : Option (String × String) :=
  let quoted (before : String) : Option String :=
    match entry.splitOn before with
    | _ :: rest :: _ =>
      match rest.splitOn "'" with
      | tool :: _ :: _ => some tool
      | _ => none
    | _ => none
  match quoted "could not execute external process '" with
  | some tool => some (tool, s!"could not execute external process '{tool}'")
  | none =>
    match quoted "failed to execute '" with
    | some tool =>
      let how :=
        match entry.splitOn s!"failed to execute '{tool}': " with
        | _ :: rest :: _ => ((rest.splitOn "\n").headD "").trimAscii.toString
        | _ => ""
      some (tool, how)
    | none => none

/-- What is said when the library of the package `owner` must be built with
`tool` and none works here (`how`), which the build job reports as is
(`Editor.PackageSet.missingTooling?`): for `cargo` it names rustup. -/
def libraryToolRequired (owner tool how : String) : String :=
  let install :=
    if tool == "cargo" then "install it with rustup from https://rustup.rs" else "install it"
  s!"{tool} is required to build {owner}'s library, and none works here ({how}): {install}, or use the package's prebuilt library, as its documentation says, then :reload"

/- Guards: a library target's missing tool, read from its log
(`libraryToolMissing?`), over the entry Lake 4.35 logged, copied verbatim
from `lake build :editorLibraries` run with no cargo on the PATH, and over
Lake's own spawn failure; a log entry that is no spawn failure, the exit
line Lake logs after it among them, is none; and the sentence the staging
fails with (`libraryToolRequired`), cargo's naming rustup. -/
#guard
  libraryToolMissing? "stderr:\ncould not execute external process 'cargo'" ==
    some ("cargo", "could not execute external process 'cargo'")

#guard
  libraryToolMissing? "failed to execute 'zig': no such file or directory (error code: 2)" ==
    some ("zig", "no such file or directory (error code: 2)")

#guard libraryToolMissing? "external command 'cargo' exited with code 255" == none

#guard libraryToolMissing? "stderr:\nerror[E0425]: cannot find value `x` in this scope" == none

#guard
  libraryToolRequired "echo" "cargo" "could not execute external process 'cargo'" ==
    "cargo is required to build echo's library, and none works here (could not execute external process 'cargo'): install it with rustup from https://rustup.rs, or use the package's prebuilt library, as its documentation says, then :reload"

#guard
  libraryToolRequired "far" "zig" "no such file or directory (error code: 2)" ==
    "zig is required to build far's library, and none works here (no such file or directory (error code: 2)): install it, or use the package's prebuilt library, as its documentation says, then :reload"

/-- What is said when the package `owner` still declares an `editorRustCrate`
target, the way a package shipped its Rust until phase 5 of
`package-native-libraries`, compiled into the editor's archive: the editor
no longer does that, and the sentence points at the way that works, a
library of its own (`setLibraries` refuses with it; the build job reports
it as is, `Editor.PackageSet.rustCrateRefused?`). -/
def rustCrateRefusal (owner : String) : String :=
  s!"{owner} declares an `editorRustCrate` target, but the editor no longer compiles a package's Rust into its own archive: ship it as a package library of its own, declared with an `editorLibrary` target and written against `editor-package` (docs/packages/writing-a-package.md, 'A native library')"

/- Guard: the refusal of a package that still declares an `editorRustCrate`
target, whole, naming the package and pointing at package libraries. -/
#guard
  rustCrateRefusal "acp" ==
    "acp declares an `editorRustCrate` target, but the editor no longer compiles a package's Rust into its own archive: ship it as a package library of its own, declared with an `editorLibrary` target and written against `editor-package` (docs/packages/writing-a-package.md, 'A native library')"

/-- A library target of a set (`setLibraries`): the Lake package that
declares it, the target's job, its value read as the library's path, and
the job as the build monitor holds it, when the target registered one.
A `target` declared with Lake's DSL registers its job and hands back a
renewed copy, whose log is moved to the monitor; the registered one keeps
it, so a failed target's log is read there (`stageLibraries`). -/
structure LibraryTarget where
  /-- The name of the Lake package that declares the target. -/
  owner : String
  /-- The target's job, its value the library's path. -/
  job : Job String
  /-- The job the target registered with the build monitor, with its log. -/
  registered : Option OpaqueJob

/-- The library targets of the set `set`, in the order its packages
register (`setPackages`): a package declares its library with a target
named `editorLibrary` (`libraryTargetName`) whose value is the library's
path, fetched through the build's store, so it runs once a build, and read
through its own declaration's query format; so this names no type of the
package's, and no list is
kept by hand. Each job is unawaited, so a failed one's log can be read
(`stageLibraries`).

A package that still declares an `editorRustCrate` target is refused first,
with `rustCrateRefusal`: the editor no longer compiles a package's Rust into
its archive. So every link (`linkAsEditor` fetches `editorLibraries`), every
install and `lake build :editorLibraries` stop on it. -/
def setLibraries (set : Package) : FetchM (Array LibraryTarget) := do
  let ws ← getWorkspace
  let mut libraries : Array LibraryTarget := #[]
  for dep in setPackages ws set do
    let owner := dep.baseName.toString (escape := false)
    if (dep.findTargetDecl? `editorRustCrate).isSome then
      error (rustCrateRefusal owner)
    let some decl := dep.findTargetDecl? libraryTargetName | continue
    let some config := decl.targetConfig?
      | error s!"the package {owner} declares `editorLibrary`, but not as a target"
    let job : Job (CustomData dep.keyName libraryTargetName) ←
      fetch (BuildInfo.target dep libraryTargetName)
    let caption := (dep.target libraryTargetName).key.toSimpleString
    let queue : IO.Ref (Array OpaqueJob) := (← getBuildContext).registeredJobs
    let registered := (← queue.get).reverse.find? (·.caption == caption)
    libraries := libraries.push { owner, job := job.map (config.format .text), registered }
  return libraries

/-- Copies the library at `source` to `place`, its bytes only, when the
bytes at `place` differ: written beside it and renamed over it, so the file
at `place` is a new one, and an editor that has the old library mapped
keeps running (on macOS, a signed library rewritten in place kills the
process that maps it). A quarantine attribute is not carried; the
library's signature, in its bytes, is. -/
def stageLibrary (source place : FilePath) : IO Unit := do
  let bytes ← IO.FS.readBinFile source
  if ← place.pathExists then
    if (← IO.FS.readBinFile place).data == bytes.data then
      return
  if let some dir := place.parent then
    IO.FS.createDirAll dir
  let beside := place.addExtension "staging"
  IO.FS.writeBinFile beside bytes
  IO.FS.rename beside place

/-- Stages the library of each Lake package of the set `set` that declares
one (`setLibraries`), in register order, under the set's build directory at
`stagedLibraryPlace` (`stageLibrary`), and answers its lines, the Lake
package and the staged library, absolute, separated by a tab.

It reads each target's result rather than awaiting its value, so a target
that failed is read, not replayed: one whose log (`LibraryTarget`) says its
tool could not be run (`libraryToolMissing?`) fails the staging with
`libraryToolRequired`, naming the package and the tool, which the build job
reports as is (`Editor.PackageSet.missingTooling?`); any other failure
names the package after the target's own log, which the monitor prints. -/
def stageLibraries (set : Package) : FetchM (Job (Array String)) := do
  let libraries ← setLibraries set
  IO.FS.createDirAll set.buildDir
  let buildDir ← IO.FS.realPath set.buildDir
  Job.async do
      let mut lines : Array String := #[]
      for { owner := lake, job, registered } in libraries do
        match ← job.wait with
        | .ok library _ =>
          let source : FilePath := library
          let some file := source.fileName
            | error s!"the package {lake}'s library (its `editorLibrary` target) names no file: {library}"
          let place := buildDir / stagedLibraryPlace lake file
          stageLibrary source place
          lines := lines.push s!"{lake}\t{place}"
        | .error _ state =>
          -- The target's log: the registered job's, which the monitor
          -- prints itself, or, for a target that registered none, its own,
          -- replayed here.
          let log ←
            match registered with
            | some monitored =>
              pure (← monitored.wait).state.log
            | none =>
              pure state.log
          match log.entries.findSome? (libraryToolMissing? ·.message) with
          | some (tool, how) =>
            error (libraryToolRequired lake tool how)
          | none =>
            if registered.isNone then
              log.replay
            error s!"the package {lake}'s library (its `editorLibrary` target) did not build"
      return lines

/-- The libraries of a package set, staged (`lake -d <set dir> query
:editorLibraries`; `stageLibraries`): one line a Lake package that declares
a library (an `editorLibrary` target), in the order the packages register,
its name and its staged library, `<set>/.lake/build/libraries/<lake>/<file>`,
separated by a tab. Empty for a set with none. Each executable linked as
the editor writes them beside itself (`linkAsEditor`), and an install copies
them (`editorInstall`). -/
package_facet editorLibraries pkg : Array String := do
  stageLibraries pkg

/-- Links an executable at `file`, rooted at the module `root`, as the
editor is linked: `root`'s object and those of every module it imports,
with their symbols exported, so interpreted config can find compiled
definitions and `@[extern]` symbols (`-rdynamic`, what `supportInterpreter`
gives a `lean_exe`), the glue of every package library it imports among
them (a library's `moreLinkObjs`); then the core's glue and the core's Rust
archive (`coreArchive`: `rustlib`, or its prebuilt copy for a user's set),
the one Rust archive of every set's editor, `libeditor_rust.a`; then
`linkArgs`, with the
workspace's toolchain's library directory (`editorLinkArgs`), then the
system libraries that archive needs: as rustc printed them, for a
compiler that finds them in the macOS SDK or on Linux; or, on macOS with
the toolchain's own `clang` (no `LEAN_CC`), whose linker finds no
framework, from the link stubs in `<repository>/link-stubs`
(`linksFromStubs`, `stubLinkArgs`), which an app bundle ships, so a user's
set links from the app alone (`docs/design/lean-runtime.md`, "The app
ships the toolchain"). With no stubs there that link fails, saying so.
`root` may be a module of any package of the
workspace: the core's glue is this package's target, built in its build
directory.

Beside `file` it writes `<file>.libraries`, the libraries of the set's
packages as `editorLibraries` staged them (`librariesRecordText`, absolute
lines; an empty record for a set with none), which a package's initialiser
reads to find its library (`Editor/ModuleLookup.lean`, "The libraries").
The staging is part of the link's job, so the link fails when a library
fails, and a library that changes is restaged without a relink. -/
def linkAsEditor (set : Package) (root : Module) (file : FilePath) : FetchM (Job FilePath) := do
  let librariesJob ← (set.facet `editorLibraries).fetch
  let recordJob ←
    librariesJob.mapM fun lines => do
        writeIfChanged (file.toString ++ ".libraries")
            (librariesRecordText
              ((stagedLibrariesOf lines).map fun (lake, library) => (lake, library.toString)))
  let infoJob ← root.linkInfoExport.fetch
  let glueJob ← glue.o.fetch
  let rustJob ← coreArchive set
  let libraries := systemLibrariesFile (rustDir (← repositoryRoot) "core")
  let entry ← editorLinkArgs
  let fromStubs := linksFromStubs Platform.isOSX (← getLeanInstall).customCc
  let stubs := linkStubsDir (← repositoryRoot)
  let linked ←
    ((infoJob.zipWith Prod.mk glueJob).zipWith Prod.mk rustJob).mapM fun ((info, glue), rust) => do
        let system ←
          if fromStubs then
            unless ← stubs.isDir do
              error
                  s!"linking with the toolchain's own clang needs link stubs at {stubs} (the link-stubs binary, crates/editor-release-std), and there are none: set LEAN_CC to a compiler that links against the macOS SDK, or build from an app bundle, which ships them"
            let names := (← stubs.readDir).map (·.fileName)
            match stubLinkArgs stubs names (← IO.FS.readFile (stubs / "platform-version")) with
            | .ok args =>
              pure args
            | .error message =>
              error message
          else
            systemLibraryArgs libraries
        addPureTrace entry "linkArgs"
        addPureTrace system "native-static-libs"
        buildLeanExeSync file ((info.objs.push glue).push rust) info.libs
            (#["-rdynamic"] ++ info.args ++ entry ++ system)
  return linked.add recordJob

/-- Whether `part` occurs in `text`, for the guards of generated text. -/
def holdsText (text part : String) : Bool :=
  (text.splitOn part).length > 1

/-- The text of a set's root module, for the entry modules `entries` in the
order they register and the config base `base` (`setBase`). It imports the
core's base, `Editor`, for the link alone (`Editor/Main.lean`, "This module
names no package, and not the config base"), then the executable's entry,
then each entry module; and its `main` is one call of `Editor.Main.run`
with the entry modules' `packages` appended in that order (`#[]` for a
set with no entry module, as a set of the core alone is), the base as an
array of names, and what the build says of the editor for the files it
generates in a config directory (`Editor/Config/LakePackage.lean`,
`Origin`): `setName`, the Lake name of the set, and `pin`, the text of the
core's `lean-toolchain`. Every module of the base is among its imports, so
each is linked into the executable, which the elaborator requires of a
module it imports at runtime.

`schemes` are the entry modules that supply an input scheme (`SetEntry.scheme`),
in the order they register: `run` is handed the `scheme` of each, as an
array, and runs the last (`Editor/Main.lean`, "The input scheme"). With
none the array is empty, and the editor refuses to start.

`shipping` are the entry modules whose Lake package ships grammars
(`SetEntry.grammars`), each with its Lake package's name: such an entry's
packages are listed as `(Editor.Package.shipping "<lake>" <M>.packages)`,
so each is tagged with the Lake package whose staged grammars directory its
grammar declarations are relative to (`Editor/Package.lean`). With none,
the root's text is as it was before grammars could be shipped. -/
def rootSource (entries schemes base : Array Name) (setName pin : String)
    (shipping : Array (Name × String) := #[]) : String :=
  let imports := entries.foldl (fun text name => text ++ s!"import {name}\n") ""
  let listed (name : Name) : String :=
    match shipping.find? (·.1 == name) with
    | some (_, lake) => s!"(Editor.Package.shipping {lake.quote} {name}.packages)"
    | none => s!"{name}.packages"
  let lists := if entries.isEmpty then "#[]" else " ++ ".intercalate (entries.map listed).toList
  let supplied := ", ".intercalate (schemes.map fun name => s!"{name}.scheme").toList
  let names := ", ".intercalate (base.map fun name => s!"`{name}").toList
  s!"import Editor
import Editor.Main
{imports}
/-!
# The executable's root, generated

Written by the package-set build (`setRoot` in `lean/lakefile.lean`) from
the Lake packages of a package set, each after the packages it requires.
Do not edit it: the build writes it again.
-/

/-- The editor, with the packages of the set's Lake packages, the input
schemes they supply, the modules
config is elaborated on, `Editor` and then the entry module of each package
of the set outside the core, and the set's Lake name and the toolchain pin,
for the lakefile and the toolchain file it generates in a config
directory. -/
def main (args : List String) : IO UInt32 :=
  Editor.Main.run ({lists}) #[{supplied}] #[{names}] \{ setName := {setName.quote}, pin := {pin.quote} } args
"

/- Guards: the root the package-set build generates (`rootSource`). With no
entry module (the core alone, or a set with no input-scheme package) it
imports `Editor` and `Editor.Main` and nothing else, and hands `run` no
package and no scheme; with two entry modules and a scheme it imports them
in order after those two, appends their packages in order and hands the
scheme; and the set's Lake name and the toolchain pin are handed as given,
quoted, so the generated config's lakefile names the set and its
`lean-toolchain` is the core's pin. -/
#guard
  (rootSource #[] #[] #[`Editor] "core-only" "leanprover/lean4:v4.35.0\n").startsWith
    "import Editor\nimport Editor.Main\n\n/-!"

#guard
  holdsText (rootSource #[] #[] #[`Editor] "core-only" "leanprover/lean4:v4.35.0\n")
    "Editor.Main.run (#[]) #[] #[`Editor] { setName := \"core-only\", pin := \"leanprover/lean4:v4.35.0\\n\" } args"

#guard
  (rootSource #[`A.EditorPackage, `B.EditorPackage] #[`B.EditorPackage]
        #[`Editor, `A.EditorPackage, `B.EditorPackage] "s" "p\n").startsWith
    "import Editor\nimport Editor.Main\nimport A.EditorPackage\nimport B.EditorPackage\n\n/-!"

#guard
  holdsText
    (rootSource #[`A.EditorPackage, `B.EditorPackage] #[`B.EditorPackage]
      #[`Editor, `A.EditorPackage, `B.EditorPackage] "s" "p\n")
    "Editor.Main.run (A.EditorPackage.packages ++ B.EditorPackage.packages) #[B.EditorPackage.scheme] #[`Editor, `A.EditorPackage, `B.EditorPackage] { setName := \"s\", pin := \"p\\n\" } args"

/- Guards: an entry module whose Lake package ships grammars has its packages
tagged with that Lake package (`Editor.Package.shipping`), in order among the
others, and the others are listed as before. -/
#guard
  holdsText
    (rootSource #[`A.EditorPackage, `IniGrammar.EditorPackage] #[] #[`Editor] "s" "p\n"
      #[(`IniGrammar.EditorPackage, "ini-grammar")])
    "Editor.Main.run (A.EditorPackage.packages ++ (Editor.Package.shipping \"ini-grammar\" IniGrammar.EditorPackage.packages)) #[]"

/-- The name of the root module the package-set build generates. No library
declares it. -/
def setRootName : Name :=
  `EditorSetRoot

/-- The keyword a Lake package declares in its lakefile when it supplies
the editor's input scheme (`keywords = ["editor-input-scheme"]`, Lake's own
package key): its entry module then
declares `scheme : Editor.SchemePackage` beside `packages`, in the
namespace of its own name (`docs/design/packages.md`, "Input schemes").
Lake is asked for the keyword, so the build reads no source: a package
that declares it and no `scheme` fails the generated root's build, which
names `<P>.EditorPackage.scheme`, as a missing `packages` does. -/
def schemeKeyword : String :=
  "editor-input-scheme"

/-- The keyword a Lake package declares in its lakefile when it ships
grammars (`keywords = ["editor-grammars"]`): their files are under its
`grammars/` directory, and its entry module's packages declare them
relative to it (`docs/design/packages.md`, "A package's grammars"). Lake is
asked for the keyword, so the build learns which packages ship grammars
without reading any source: the `editorGrammars` facet stages each such
package's `grammars/`, with the libraries it compiles from the package's
grammar source when it declares one (`grammarSourcesTargetName`), the
`editor` facet records where, the install copies it (`editorInstall`) and
the bundle lists it (`editorShipped`). A package that declares it with no
entry module, or with no `grammars/` directory, fails the set's build with
a message naming it (`setEntries`). -/
def grammarsKeyword : String :=
  "editor-grammars"

/-- An entry module of a set. -/
structure SetEntry where
  /-- Whether its Lake package is this one, the core. -/
  core : Bool
  /-- The module's name. -/
  module : Name
  /-- Whether its Lake package supplies an input scheme (`schemeKeyword`). -/
  scheme : Bool
  /-- Whether its Lake package ships grammars (`grammarsKeyword`). -/
  grammars : Bool := false
  /-- Its Lake package's name, as its lakefile gives it. -/
  lake : String := ""

/-- The entry modules of the set `pkg`, in the order they register
(`setPackages`, `entryModule?`), each with whether its Lake package is this
one, the core, and whether it supplies an input scheme (`schemeKeyword`).
The core has no entry module, so none of them is the core's; `core` is
kept so that a core with one would still stay out of the base (`setBase`).
A package that declares the scheme keyword and has no entry module is an
error that names it: there is nowhere for its scheme to be declared. So is
one that declares the grammars keyword (`grammarsKeyword`) with no entry
module, or with no `grammars/` directory. Each entry also says whether its
Lake package ships grammars, and that package's name. -/
def setEntries (pkg : Package) : FetchM (Array SetEntry) := do
  let ws ← getWorkspace
  let mut entries : Array SetEntry := #[]
  for dep in setPackages ws pkg do
    let scheme := dep.keywords.contains schemeKeyword
    let grammars := dep.keywords.contains grammarsKeyword
    let lake := dep.baseName.toString (escape := false)
    if grammars && !(← (dep.dir / "grammars").isDir) then
      error
          s!"the package {lake} declares the keyword {grammarsKeyword} and has no grammars directory {dep.dir / "grammars"}: a package that ships grammars keeps their files there"
    match ← entryModule? dep with
    | some mod =>
      entries :=
        entries.push { core := dep.keyName == __name__, module := mod.name, scheme, grammars, lake }
    | none =>
      if scheme then
        error
            s!"the package {lake} declares the keyword {schemeKeyword} and has no entry module {entryModuleName dep}: a package that supplies the input scheme declares `scheme` there"
      if grammars then
        error
            s!"the package {lake} declares the keyword {grammarsKeyword} and has no entry module {entryModuleName dep}: a package that ships grammars declares them on its packages there"
  return entries

/-- The config base of a set, from its entry modules (`setEntries`): the
modules its editor elaborates config on. `Editor`, the core's base
(`Editor.lean`), then the entry module of each package of the set outside
the core, in the order they register, so that config can name what a
package of the set declares: an entry module imports its package's modules.
The core has no entry module, and one of the core's would not be in it:
the core's base is `Editor`, and
what config sees of the core does not change with the set
(`docs/design/packages.md`, "The package set and its build"). -/
def setBase (entries : Array SetEntry) : Array Name :=
  #[`Editor] ++ (entries.filter (!·.core)).map (·.module)

/- Guards: the config base of a set (`setBase`). A set with no entry module,
the empty set, has `Editor` alone; a core entry module stays out of it, and
each package's is kept, after `Editor`, in order. -/
#guard setBase #[] == #[`Editor]

#guard
  setBase
      #[{ core := true, module := `Core.EditorPackage, scheme := false },
        { core := false, module := `A.EditorPackage, scheme := false },
        { core := false, module := `B.EditorPackage, scheme := true }] ==
    #[`Editor, `A.EditorPackage, `B.EditorPackage]

/-- The library a set's generated root module is a module of, named `name`
in the set's package `pkg` (`setRoot`'s `EditorSet`, `fixturesRoot`'s
`EditorSetFixtures`): no library of the set declares it, so it is a value
made here, whose source directory is `<set>/.lake/build/root`. It takes
this package's Lean options, so a warning in the root fails the build, and
loads the build's linters as a plugin (`lintPlugin`), as every library
does (`.agents/rules/structure.md`, "Lint plugins"). -/
def generatedLib (pkg : Package) (name : Name) : LeanLib :=
  ⟨pkg, name,
    { srcDir := pkg.config.buildDir / "root", roots := #[], leanOptions := coreLeanOptions
      plugins := lintPlugin }⟩

/-- The root module of the set `pkg`, written from the entry modules of the
set's packages (`setEntries`, `setBase`, `rootSource`), the set's Lake name
and the text of the core's `lean-toolchain`, to
`<set>/.lake/build/root/EditorSetRoot.lean`, and only when its text would
change, so a build with nothing to do writes nothing.

No library of the set declares the module: it is a module of a library
value made here, in the set's package (`generatedLib`), whose source
directory is that directory, so its `.olean` and its object are in the
set's build directory. That library takes this package's Lean options, so
a warning in the root fails the build, and loads the lint plugin. Lake
builds an executable's root the same way (`LeanExe.root`). -/
def setRoot (pkg : Package) : FetchM Module := do
  let entries ← setEntries pkg
  let root : Module := { lib := generatedLib pkg `EditorSet, name := setRootName }
  let ws ← getWorkspace
  let some core := ws.findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  -- The pin is the core's: every other `lean-toolchain` in the repository
  -- is a link to that one file.
  let pin ← IO.FS.readFile (core.dir / "lean-toolchain")
  writeIfChanged root.leanFile
      (rootSource (entries.map (·.module)) ((entries.filter (·.scheme)).map (·.module))
        (setBase entries) (pkg.baseName.toString (escape := false)) pin
        ((entries.filter (·.grammars)).map fun entry => (entry.module, entry.lake)))
  return root

/-- The `.olean` directories of a set whose core is the package `core`, its
directory `coreDir`, and whose packages, in the order they register, are
`packages`, each its key, whether it holds a Lean library and its
directory: the core's first, then that of each other package that holds a
library, in order (`moduleDirectories`). -/
def moduleDirectoriesOf (core : Name) (coreDir : FilePath)
    (packages : Array (Name × Bool × FilePath)) : Array FilePath :=
  #[coreDir] ++ (packages.filter fun (key, hasLib, _) => key != core && hasLib).map (·.2.2)

/-- The `.olean` directories of the set `pkg`: the core's first, then that
of each other package of the set that holds a Lean library, in the order
they register (`setPackages`). They are what the set's editor searches for
the modules of its config base (`setBase`). -/
def moduleDirectories (pkg : Package) : FetchM (Array FilePath) := do
  let ws ← getWorkspace
  let some core := ws.findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  return moduleDirectoriesOf __name__ core.leanLibDir
      ((setPackages ws pkg).map fun dep => (dep.keyName, !dep.leanLibs.isEmpty, dep.leanLibDir))

/- Guards: the `.olean` directories of a set (`moduleDirectoriesOf`, which
`moduleDirectories` takes from Lake): the core's first, then each other
package's that holds a library, in the order they register; a package with
no library, and the core where the set's packages name it again, are
dropped. -/
#guard
  moduleDirectoriesOf `core "/r/lean/.lake/build/lib/lean"
      #[(`core, true, "/r/lean/.lake/build/lib/lean"), (`api, true, "/r/packages/api/lib"),
        (`set, false, "/r/packages/lib"), (`compile, true, "/r/packages/compile/lib")] ==
    (#["/r/lean/.lake/build/lib/lean", "/r/packages/api/lib", "/r/packages/compile/lib"] :
      Array FilePath)

#guard moduleDirectoriesOf `core "/c" #[] == (#["/c"] : Array FilePath)

/-- The record of where the `.olean` files of a set's packages are, written
beside the editor the set's build links, at `<executable>.oleans`: one
directory a line (`moduleDirectories`), the core's first, then that of each
other package of the set that holds a Lean library, in the order they
register.

The editor is linked into the set's build directory, and each package's
modules are built in that package's own, so no directory relative to the
executable holds the modules config is elaborated on. An editor run
directly, outside a bundle, reads this record and searches every directory
of it (`Editor/ModuleLookup.lean`, "The record"). It is written only when
its text would change. -/
def writeModuleRecord (pkg : Package) (executable : FilePath) : FetchM Unit := do
  let directories ← moduleDirectories pkg
  writeIfChanged (executable.toString ++ ".oleans")
      (directories.foldl (fun text directory => text ++ s!"{directory}\n") "")

/-- The text of the record `<executable>.set` for the set at `dir`, resolved:
the directory, on one line (`writeSetRecord`). -/
def setRecordText (dir : FilePath) : String :=
  s!"{dir}\n"

/-- The text of the record `<executable>.coredir` for the core whose
directory Lake holds as `coreDir`, with `cwd` the working directory: the
directory, made absolute against `cwd` when it is relative and never
resolved through links, on one line (`writeCoreDirRecord`). -/
def coreDirRecordText (coreDir cwd : FilePath) : String :=
  s!"{if coreDir.isAbsolute then coreDir else cwd / coreDir}\n"

/-- The record of where a package set is, written beside the editor the
set's build links, at `<executable>.set`: the set's directory, absolute,
on one line. An editor run directly, outside a bundle, reads it
(`Editor/ModuleLookup.lean`, "The set") to name the set in the lakefile it
generates for a config directory, so that Lean's language server, started
there, finds the modules config imports. It is written only when its text
would change. -/
def writeSetRecord (pkg : Package) (executable : FilePath) : FetchM Unit := do
  writeIfChanged (executable.toString ++ ".set") (setRecordText (← IO.FS.realPath pkg.dir))

/-- The record of where the core a set's editor links is, written beside
the editor the set's build links, at `<executable>.coredir`: the directory
of the workspace's `editor-core` package, the core Lake actually linked,
absolute, on one line, as Lake spells it (made absolute against the
working directory when Lake holds it relative; never resolved through
links, so it is the same text a config's lakefile requires the core by).
An editor run directly, outside a bundle, reads it
(`Editor/ModuleLookup.lean`, "The core") to require the core at the root of
the lakefiles it writes, and its package-set build holds the set's
manifest to it. A per-user install copies it as `editor.coredir`
(`editorInstall`). It is written only when its text would change. -/
def writeCoreDirRecord (executable : FilePath) : FetchM Unit := do
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  writeIfChanged (executable.toString ++ ".coredir") (coreDirRecordText core.dir (← IO.currentDir))

/- Guards: the records the package-set build writes beside the editor for
where the set and the core are (`setRecordText`, `coreDirRecordText`): one
line each, the directory; the core's made absolute against the working
directory when Lake holds it relative, and never resolved through
links. -/
#guard setRecordText "/r/packages" == "/r/packages\n"

#guard coreDirRecordText "/r/lean" "/w" == "/r/lean\n"

#guard coreDirRecordText "../lean" "/r/packages" == "/r/packages/../lean\n"

/-- The text of the record `<executable>.grammars` (`writeGrammarsRecord`)
for `entries`, each a Lake package's name and the directory its grammars
directory is staged in: one line `<lake><TAB><directory>` each, in order
(`Editor/ModuleLookup.lean`, "The grammars"); nothing for none. -/
def grammarsRecordText (entries : Array (String × String)) : String :=
  entries.foldl (fun text (lake, directory) => text ++ s!"{lake}\t{directory}\n") ""

/-- The grammars record of an install (`editorInstall`) of a set whose Lake
packages `lakes` ship grammars: one relative line `<lake><TAB>grammars/<lake>`
each, in order, so the install's directory can be renamed into place. -/
def installGrammarsRecord (lakes : Array String) : String :=
  grammarsRecordText (lakes.map fun lake => (lake, s!"grammars/{lake}"))

/-- Where a set's build stages the grammars directory of its Lake package
`lake`, under the set's build directory: `grammars/<lake>`. -/
def stagedGrammarsPlace (lake : String) : FilePath :=
  "grammars" / lake

/- Guards: the grammars records and places (`grammarsRecordText`,
`installGrammarsRecord`, `stagedGrammarsPlace`): a line per Lake package
that ships grammars, its name, a tab and its directory; none for none; an
install's lines relative, under its own `grammars/`; and the staged place
under the set's build directory named after the Lake package. -/
#guard
  grammarsRecordText #[("ini-grammar", "/s/.lake/build/grammars/ini-grammar")] ==
    "ini-grammar\t/s/.lake/build/grammars/ini-grammar\n"

#guard grammarsRecordText #[] == ""

#guard installGrammarsRecord #["ini-grammar"] == "ini-grammar\tgrammars/ini-grammar\n"

#guard stagedGrammarsPlace "ini-grammar" == ("grammars/ini-grammar" : FilePath)

/-- Copies the directory `source` into `copy`, each file's bytes, every
directory under it made, following links, so the copy holds the files a
link names rather than a link that may dangle. -/
partial def copyTree (source copy : FilePath) : IO Unit := do
  IO.FS.createDirAll copy
  for entry in ← source.readDir do
    if ← entry.path.isDir then
      copyTree entry.path (copy / entry.fileName)
    else
      IO.FS.writeBinFile (copy / entry.fileName) (← IO.FS.readBinFile entry.path)

/-- The Lake packages of the set `pkg` that ship grammars (`grammarsKeyword`),
in the order they register, each with its name and the directory the set's
build stages its grammars directory in (`stagedGrammarsPlace` under the
set's build directory), absolute. -/
def stagedGrammars (pkg : Package) : FetchM (Array (Package × String × FilePath)) := do
  let ws ← getWorkspace
  IO.FS.createDirAll pkg.buildDir
  let buildDir ← IO.FS.realPath pkg.buildDir
  return (setPackages ws pkg).filterMap fun dep =>
      if dep.keywords.contains grammarsKeyword then
        let lake := dep.baseName.toString (escape := false)
        some (dep, lake, buildDir / stagedGrammarsPlace lake)
      else none

/-- The name of the input file a Lake package that ships grammars from
source declares (`docs/design/packages.md`, "A package's grammars", "From
source"): a Lake `input_file` whose path is the `Cargo.toml` of the
package's grammar-source crate, whose build script compiles each grammar
with `editor-grammar-build` and whose binary prints one line a grammar
(`grammarSourceLinesOf`). A TOML lakefile declares it as `[[input_file]]
name = "editorGrammarSources"`. A package that declares it, but not as an
input file, fails the set's build naming the package
(`grammarSourcesManifest?`). -/
def grammarSourcesTargetName : Name :=
  `editorGrammarSources

/-- The platform of Lean's target triple `target`, `<os>-<arch>`, as a
grammar declaration names it: a copy of `Language.Grammar.platformOf`
(`Editor/Language/Grammar.lean`), since a lakefile cannot import the
editor's modules; the guards below pin it to the four names the core's own
guards pin (`ModelTest.grammarDeclarationChecks`). -/
def grammarPlatformOf (triple : String) : String :=
  let parts := triple.splitOn "-"
  let arch : Option String :=
    match parts.head? with
    | some "arm64" | some "aarch64" => some "aarch64"
    | some "x86_64" => some "x86_64"
    | _ => none
  let os : Option String :=
    if parts.any (·.startsWith "darwin") then some "darwin"
    else if parts.contains "linux" then some "linux" else none
  match os, arch with
  | some os, some arch => s!"{os}-{arch}"
  | _, _ => triple

/- Guards: the platform of a target triple (`grammarPlatformOf`), the four
names a grammar declaration lists. -/
#guard grammarPlatformOf "arm64-apple-darwin23.5.0" == "darwin-aarch64"

#guard grammarPlatformOf "x86_64-apple-darwin" == "darwin-x86_64"

#guard grammarPlatformOf "aarch64-unknown-linux-gnu" == "linux-aarch64"

#guard grammarPlatformOf "x86_64-unknown-linux-gnu" == "linux-x86_64"

/-- Where a compiled library of the grammar `name` goes under a grammars
directory, on the platform `platform`, `isOSX` saying whether it is macOS:
`<platform>/libtree-sitter-<name>.dylib`, or `.so` off macOS, the layout a
prebuilt package ships. -/
def stagedGrammarLibraryPlace (platform name : String) (isOSX : Bool) : FilePath :=
  platform / s!"libtree-sitter-{name}.{if isOSX then "dylib" else "so"}"

/-- Where the set's build keeps a library of the grammar `name` it compiled
from a package's source, under that package's build directory, so a set
outside the repository can take it without Cargo (`GrammarSourceForm.built`):
`grammars/<platform>/libtree-sitter-<name>.<ext>`. -/
def builtGrammarsPlace (platform name : String) (isOSX : Bool) : FilePath :=
  "grammars" / stagedGrammarLibraryPlace platform name isOSX

/- Guards: the staged and built places of a compiled grammar library
(`stagedGrammarLibraryPlace`, `builtGrammarsPlace`), a `.dylib` on macOS and
a `.so` off it. -/
#guard
  stagedGrammarLibraryPlace "darwin-aarch64" "yaml" true ==
    ("darwin-aarch64/libtree-sitter-yaml.dylib" : FilePath)

#guard
  stagedGrammarLibraryPlace "linux-x86_64" "yaml" false ==
    ("linux-x86_64/libtree-sitter-yaml.so" : FilePath)

#guard
  builtGrammarsPlace "darwin-aarch64" "yaml" true ==
    ("grammars/darwin-aarch64/libtree-sitter-yaml.dylib" : FilePath)

/-- Where the set's build writes the library of the grammar `name` it
compiled with Cargo on the platform `platform`: its staged place under the
staged grammars directory `staged` (`stagedGrammarLibraryPlace`); and, when
the package is in the repository (`packageInRepository`), its built place
under the package's build directory `buildDir` (`builtGrammarsPlace`), which
a set outside the repository takes with no Cargo. A package outside the
repository, a third party's, never gets built libraries: they would be
taken by every later build of it (`GrammarSourceForm.built`) and never
compiled again, though its pin or its source changed. -/
def compiledGrammarPlaces (packageInRepository : Bool) (staged buildDir : FilePath)
    (platform name : String) (isOSX : Bool) : Array FilePath :=
  let stagedPlace := staged / stagedGrammarLibraryPlace platform name isOSX
  if packageInRepository then #[stagedPlace, buildDir / builtGrammarsPlace platform name isOSX]
  else #[stagedPlace]

/- Guards: where a library compiled with Cargo is written
(`compiledGrammarPlaces`): for a package in the repository, its staged
place and its built place under the package's build directory; for one
outside it, a third party's, its staged place alone, so its build directory
never holds built libraries and every build of it runs Cargo. -/
#guard
  compiledGrammarPlaces true "/s/.lake/build/grammars/languages" "/r/packages/languages/.lake/build"
      "darwin-aarch64" "yaml" true ==
    #[("/s/.lake/build/grammars/languages/darwin-aarch64/libtree-sitter-yaml.dylib" : FilePath),
      ("/r/packages/languages/.lake/build/grammars/darwin-aarch64/libtree-sitter-yaml.dylib" :
        FilePath)]

#guard
  compiledGrammarPlaces false "/u/set/.lake/build/grammars/mylang" "/u/mylang/.lake/build"
      "linux-x86_64" "mylang" false ==
    #[("/u/set/.lake/build/grammars/mylang/linux-x86_64/libtree-sitter-mylang.so" : FilePath)]

/-- Where a Lake package's grammar libraries come from, in a set's build
(`grammarSourceForm`). -/
inductive GrammarSourceForm where
  /-- The package's own `grammars/` holds them, or it declares no source:
  the staged copy is all there is, and no Cargo runs. -/
  | shipped
  /-- Compiled from the package's source by its grammar-source crate, run
  with Cargo. -/
  | cargo
  /-- Taken from the package's build directory, where a build in the
  repository left them: no Cargo runs. -/
  | built
  deriving DecidableEq, Repr

/-- Where a package's grammar libraries come from (`docs/design/packages.md`,
"A package's grammars", "From source"), given whether it declares a
grammar source (`grammarSourcesTargetName`), whether its own `grammars/`
holds this platform's directory, whether the set is in the repository
(`isInRepository`, as `coreArchive` decides), and whether its build
directory holds this platform's built libraries (`builtGrammarsPlace`):
shipped when it declares no source or ships this platform's directory;
otherwise Cargo for a set in the repository, so the checkout's own build is
never stale; the built ones for a set outside it that has them, the
counterpart of `prebuiltRust`, so a user's set over the checkout's default
set runs no Cargo; and Cargo for one outside it with none. -/
def grammarSourceForm (declares shippedHere inRepository builtHere : Bool) : GrammarSourceForm :=
  if !declares || shippedHere then .shipped
  else if inRepository then .cargo else if builtHere then .built else .cargo

/- Guards: the forms (`grammarSourceForm`). No source, or this platform's
directory in the package, is shipped whatever else holds; in the repository
it is Cargo, built or not; outside it, the built libraries when there are
some, else Cargo. -/
#guard grammarSourceForm false false false false == .shipped

#guard grammarSourceForm false false true true == .shipped

#guard grammarSourceForm true true true false == .shipped

#guard grammarSourceForm true true false true == .shipped

#guard grammarSourceForm true false true false == .cargo

#guard grammarSourceForm true false true true == .cargo

#guard grammarSourceForm true false false true == .built

#guard grammarSourceForm true false false false == .cargo

/-- One line a package's grammar-source crate prints
(`grammarSourceLinesOf`). -/
inductive GrammarSourceLine where
  /-- The grammar `name` compiled into `library`. -/
  | built (name : String) (library : FilePath)
  /-- The grammar `name` did not compile, for `reason`. -/
  | failed (name : String) (reason : String)
  deriving BEq, Repr

/-- Whether `name` can be a grammar's name: lowercase ASCII letters, digits
and underscores, at least one, since its symbol is `tree_sitter_<name>`. -/
def isGrammarName (name : String) : Bool :=
  !name.isEmpty && name.all fun c => ('a' ≤ c && c ≤ 'z') || c.isDigit || c == '_'

/-- The lines a package's grammar-source crate prints, read: one a grammar,
`built<TAB><name><TAB><library>` or `failed<TAB><name><TAB><reason>`; a
blank line is skipped, and any other line, or a name a grammar cannot have
(`isGrammarName`), is refused, naming the line. -/
def grammarSourceLinesOf (text : String) : Except String (Array GrammarSourceLine) :=
  (text.splitOn "\n").foldlM
    (fun lines line => do
      if line.trimAscii.isEmpty then
        return lines
      match line.splitOn "\t" with
      | [kind, name, value] =>
        unless isGrammarName name do
          throw
              s!"the grammar sources named the grammar {repr name}, which no grammar can be named: {repr line}"
        match kind with
        | "built" =>
          return lines.push (.built name value)
        | "failed" =>
          return lines.push (.failed name value)
        | _ =>
          throw s!"the grammar sources printed a line that is no grammar's: {repr line}"
      | _ =>
        throw s!"the grammar sources printed a line that is no grammar's: {repr line}")
    #[]

/- Guards: the crate's lines read (`grammarSourceLinesOf`): a built line and
a failed line, a blank trailing line skipped; a line of another shape
refused; and a name outside `[a-z0-9_]` refused. -/
#guard
  (grammarSourceLinesOf
        "built\tyaml\t/t/libtree-sitter-yaml.dylib\nfailed\tbroken\tthe C compiler failed: x\n").toOption ==
    some
      #[.built "yaml" "/t/libtree-sitter-yaml.dylib", .failed "broken" "the C compiler failed: x"]

#guard (grammarSourceLinesOf "").toOption == some #[]

#guard
  grammarSourceLinesOf "warning: something\n" matches
    .error "the grammar sources printed a line that is no grammar's: \"warning: something\""

#guard
  grammarSourceLinesOf "built\tc-sharp\t/t/l.so\n" matches
    .error
      "the grammar sources named the grammar \"c-sharp\", which no grammar can be named: \"built\\tc-sharp\\t/t/l.so\""

/-- What the set's build fails with when the grammar `grammar` of the Lake
package `lake` did not compile from its source, for `reason`. -/
def grammarDidNotCompile (lake grammar reason : String) : String :=
  s!"the package `{lake}`'s grammar `{grammar}` did not compile from its source: {reason}"

/-- What the set's build fails with when the Cargo run of the Lake package
`lake`'s grammar-source crate, whose manifest is `manifest`, did not end
well, after Cargo's own log. -/
def grammarSourcesDidNotBuild (lake : String) (manifest : FilePath) : String :=
  s!"the package `{lake}`'s grammar sources (its `editorGrammarSources` target, `{manifest}`) did not build"

/- Guards: the two sentences, whole (`grammarDidNotCompile`,
`grammarSourcesDidNotBuild`). -/
#guard
  grammarDidNotCompile "broken-grammar" "broken" "the C compiler failed: x" ==
    "the package `broken-grammar`'s grammar `broken` did not compile from its source: the C compiler failed: x"

#guard
  grammarSourcesDidNotBuild "languages" "/r/packages/languages/rust/Cargo.toml" ==
    "the package `languages`'s grammar sources (its `editorGrammarSources` target, `/r/packages/languages/rust/Cargo.toml`) did not build"

/-- The manifest of the grammar-source crate the Lake package `dep`
declares (`grammarSourcesTargetName`): the declared input file's path, under
the package's directory unless it is absolute; none when it declares none.
One declared as anything but an input file fails, naming the package. -/
def grammarSourcesManifest? (dep : Package) : FetchM (Option FilePath) := do
  let some decl := dep.findTargetDecl? grammarSourcesTargetName | return none
  let some config := decl.config? InputFile.configKind
    |
    error
        s!"the package {dep.baseName.toString (escape := false)} declares `editorGrammarSources`, but not as an input file"
  return some (dep.dir / config.path)

/-- The libraries of the Lake package `lake` that its grammar-source crate
`manifest` builds, run with Cargo (`cargo run --release --locked --quiet`,
`cargo` the bare name, as `buildRust` runs it): each grammar's name and
library, read from the lines its binary prints (`grammarSourceLinesOf`). A
Cargo that does not end well fails with `grammarSourcesDidNotBuild` after
Cargo's log; a line that says a grammar did not compile fails with
`grammarDidNotCompile`, after the compiler's output, which the binary
writes on standard error. -/
def grammarSourceLibraries (lake : String) (manifest : FilePath) :
    JobM (Array (String × FilePath)) := do
  let out ←
    rawProc (quiet := true)
        { cmd := "cargo"
          args :=
            #["run", "--release", "--locked", "--quiet", "--manifest-path", manifest.toString] }
  if out.exitCode != 0 then
    logOutput out logInfo
    error (grammarSourcesDidNotBuild lake manifest)
  match grammarSourceLinesOf out.stdout with
  | .error reason =>
    logOutput out logInfo
    error s!"{grammarSourcesDidNotBuild lake manifest}: {reason}"
  | .ok lines =>
    let mut libraries : Array (String × FilePath) := #[]
    for line in lines do
      match line with
      | .built name library =>
        libraries := libraries.push (name, library)
      | .failed name reason =>
        unless out.stderr.isEmpty do
          logInfo s!"stderr:\n{out.stderr.trimAscii}"
        error (grammarDidNotCompile lake name reason)
    return libraries

/-- The grammars directories of the set `pkg`, staged (`lake -d <set dir>
query :editorGrammars`; `docs/design/packages.md`, "A package's grammars"):
one line `<lake><TAB><staged directory>` for each Lake package that ships
grammars (`stagedGrammars`), in the order the packages register, the
directory absolute. For each, it copies the package's `grammars/` to its
staged place, a fresh copy each build (`copyTree`), then stages its
libraries at `stagedGrammarLibraryPlace` from where `grammarSourceForm`
says: nothing more when shipped; compiled with Cargo
(`grammarSourceLibraries`), each library also written under the package's
build directory (`builtGrammarsPlace`) when the package is in the repository
(`compiledGrammarPlaces`); or copied from that directory when built, which
only a package in the repository can be. Each library is written beside its place and renamed over it
(`stageLibrary`). The editor writes the lines as its record
`<executable>.grammars` (`editor`), the install copies each directory
(`editorInstall`) and the bundle lists each as its package's `grammars/`
(`editorShipped`). -/
package_facet editorGrammars pkg : Array String := do
  let staged ← stagedGrammars pkg
  let root ← repositoryRoot
  let inRepository ← isInRepository root pkg
  let mut planned : Array (Package × String × FilePath × Option FilePath × Bool) := #[]
  for (dep, lake, directory) in staged do
    planned :=
      planned.push (dep, lake, directory, ← grammarSourcesManifest? dep, ← isInRepository root dep)
  Job.async do
      let platform := grammarPlatformOf System.Platform.target
      let mut lines : Array String := #[]
      for (dep, lake, directory, manifest?, packageInRepository) in planned do
        if ← directory.pathExists then
          IO.FS.removeDirAll directory
        copyTree (dep.dir / "grammars") directory
        let built := dep.buildDir / "grammars" / platform
        -- Only a package in the repository has built libraries to take
        -- (`compiledGrammarPlaces`); one outside it left by an older build
        -- is not taken.
        let form :=
          grammarSourceForm manifest?.isSome (← (dep.dir / "grammars" / platform).isDir)
            inRepository (packageInRepository && (← built.isDir))
        match form, manifest? with
        | .cargo, some manifest =>
          for (name, library) in ← grammarSourceLibraries lake manifest do
            for place in
              compiledGrammarPlaces packageInRepository directory dep.buildDir platform name
                Platform.isOSX do
              stageLibrary library place
        | .built, _ =>
          for entry in ← built.readDir do
            stageLibrary entry.path (directory / platform / entry.fileName)
        | _, _ =>
          pure ()
        lines := lines.push s!"{lake}\t{directory}"
      return lines

/-- The variables a rebuild of a set must run with as the link did, and
which the record `<executable>.build` holds (`buildRecordText`): the C
compiler Lake compiles and links with (`LEAN_CC`; `mise run lean` sets
`/usr/bin/cc`) and the lowest macOS the link targets
(`MACOSX_DEPLOYMENT_TARGET`). A user's set rebuilt without them could make
the core's shared outputs out of date, or fail to link the system
frameworks (`docs/design/packages.md`, "User package sets"). -/
def buildVariables : Array String :=
  #["LEAN_CC", "MACOSX_DEPLOYMENT_TARGET"]

/-- The text of the record `<executable>.build`, with `lookup` the value of
a variable, none when it is unset: one line `NAME=value` for each of
`buildVariables` that is set, in that order; nothing for one that is
unset. -/
def buildRecordOf (lookup : String → Option String) : String :=
  buildVariables.foldl
    (fun text name =>
      match lookup name with
      | some value => text ++ s!"{name}={value}\n"
      | none => text)
    ""

/-- The text of the record `<executable>.build`: one line `NAME=value` for
each of `buildVariables` that is set, in that order, as the environment of
this build holds it; nothing for one that is unset (`buildRecordOf`). -/
def buildRecordText : IO String := do
  let values ← buildVariables.mapM fun name => return (name, ← IO.getEnv name)
  return buildRecordOf fun name => (values.find? (·.1 == name)).bind (·.2)

/- Guards: the record `<executable>.build` (`buildRecordOf`): a line for each
of `buildVariables` that is set, in that order, and nothing for one that is
unset. -/
#guard
  buildRecordOf
      (fun
        | "LEAN_CC" => some "/usr/bin/cc"
        | "MACOSX_DEPLOYMENT_TARGET" => some "26.0"
        | _ => none) ==
    "LEAN_CC=/usr/bin/cc\nMACOSX_DEPLOYMENT_TARGET=26.0\n"

#guard
  buildRecordOf
      (fun
        | "MACOSX_DEPLOYMENT_TARGET" => some "26.0"
        | _ => none) ==
    "MACOSX_DEPLOYMENT_TARGET=26.0\n"

#guard buildRecordOf (fun _ => none) == ""

/-- The core's identity from what it mixes (`coreIdentity`): the hashes of
the objects of the core's modules, `objects`, the glue's, `glue`, the Rust
archive's, `rust`, and the version of the Lean toolchain, `version`, mixed
in that order, in hex. It takes no set. -/
def coreIdentityOf (objects : Array Hash) (glue rust : Hash) (version : String) : String :=
  ((objects ++ #[glue, rust, pureHash version]).foldl Hash.mix Hash.nil).hex

/-- The core's identity, as a job: a hash, in hex, of what an editor links
of the core, so two editors over one core have the same identity whatever
their sets hold, and any change to the core gives a new one
(`docs/design/packages.md`, "User package sets"). It mixes the traces of
the objects of every module of the core's library (`Editor`; the whole
library, so a package that imports a core module
the default set does not link still has its core's identity), the core's
glue (`glue.o`), the core's Rust archive (`coreArchive`: `rustlib`, or
the same archive reused for a user's set) and the version of the Lean
toolchain Lake runs on. The objects' traces are Lake's input hashes,
which change when a module's source, its imports or the compiler change. -/
def coreIdentity (pkg : Package) : FetchM (Job String) := do
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  let mut libraries : Array (Job (Array Module)) := #[]
  for name in [`Editor] do
    let some lib := core.leanLibs.find? (·.name == name)
      | error s!"the core's library {name} is not in the workspace"
    libraries := libraries.push (← lib.modules.fetch)
  let objects ←
    (Job.collectArray libraries).bindM fun libraries => do
        let jobs ← libraries.flatten.mapM (·.oExport.fetch)
        return (Job.collectArray jobs).map fun _ => jobs.map (·.getTrace.hash)
  let glueJob ← glue.o.fetch
  let rustJob ← coreArchive pkg
  let inputs :=
    (objects.zipWith (fun hashes _ => hashes) glueJob).zipWith (fun hashes _ => hashes) rustJob
  inputs.mapM fun hashes => do
      return coreIdentityOf hashes glueJob.getTrace.hash rustJob.getTrace.hash Lean.versionString

/- Guards: the core's identity (`coreIdentityOf`, which `coreIdentity` mixes
from Lake's traces): 16 lowercase hex digits, taking no set, and a change
to any of its inputs (a module's object, the glue, the Rust archive or the
toolchain's version) changes it. -/
#guard
  let identity := coreIdentityOf #[⟨1⟩, ⟨2⟩] ⟨3⟩ ⟨4⟩ "4.35.0"
  identity.length == 16 && identity.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

#guard
  let identity := coreIdentityOf #[⟨1⟩, ⟨2⟩] ⟨3⟩ ⟨4⟩ "4.35.0"
  [coreIdentityOf #[⟨1⟩, ⟨5⟩] ⟨3⟩ ⟨4⟩ "4.35.0", coreIdentityOf #[⟨1⟩] ⟨3⟩ ⟨4⟩ "4.35.0",
        coreIdentityOf #[⟨1⟩, ⟨2⟩] ⟨5⟩ ⟨4⟩ "4.35.0", coreIdentityOf #[⟨1⟩, ⟨2⟩] ⟨3⟩ ⟨5⟩ "4.35.0",
        coreIdentityOf #[⟨1⟩, ⟨2⟩] ⟨3⟩ ⟨4⟩ "4.36.0"].all
    (· != identity)

/-- The editor of a package set: `lake -d <set dir> build :editor` gives
`<set>/.lake/build/bin/editor`.

A package set is a Lake package whose `require`s are the set; its lakefile
declares no target. This facet is the package-set build
(`docs/design/packages.md`, "The package set and its build"): it writes
the set's root module (`setRoot`), builds it with every module it imports,
each in its own package's build directory, and links it as the editor is
linked (`linkAsEditor`). Beside the executable it records where the
`.olean` files of the set's packages are (`writeModuleRecord`) and where
the set itself is (`writeSetRecord`) and where the core it links is
(`writeCoreDirRecord`), which an editor run directly reads; it stages the
`grammars/` directory of each package that ships grammars under the set's
build directory, with the libraries it compiles from a package's grammar
source, and records where in `<executable>.grammars` (`editorGrammars`),
which the editor resolves those packages' grammar declarations against; it
stages the library of each package that declares
one (an `editorLibrary` target) under `libraries/<lake>/` there and records
where in `<executable>.libraries` (`editorLibraries`, through
`linkAsEditor`), which each package's initialiser loads its library from;
and two records a user's set build reads (`docs/design/packages.md`, "User
package sets"): `<executable>.core`, the core's identity (`coreIdentity`),
one line, and `<executable>.build`, the environment the link ran with
(`buildRecordText`). Each is written only when its text would change. It is defined here because the link's objects and
arguments are the core's knowledge, and a lakefile cannot import another's
definitions; a facet reaches every package of a workspace that holds this
one.

It is the only way an editor is built: this package declares no `editor`
executable, and no root module is written by hand. The executable imports
the config session, so Lean's elaborator is linked in. -/
package_facet editor pkg : FilePath := do
  let executable := pkg.binDir / "editor"
  writeModuleRecord pkg executable
  writeSetRecord pkg executable
  writeCoreDirRecord executable
  writeIfChanged (executable.toString ++ ".build") (← buildRecordText)
  let grammars ←
    (← (pkg.facet `editorGrammars).fetch).mapM fun lines =>
        writeIfChanged (executable.toString ++ ".grammars")
          (grammarsRecordText
            ((stagedLibrariesOf lines).map fun (lake, directory) => (lake, directory.toString)))
  let identity ←
    (← coreIdentity pkg).mapM fun identity =>
        writeIfChanged (executable.toString ++ ".core") s!"{identity}\n"
  return ((← linkAsEditor pkg (← setRoot pkg) executable).add identity).add grammars

/-- The variable `editorInstall` takes the directory it installs into from. -/
def installDirVar : String :=
  "EDITOR_INSTALL_DIR"

/-- The `.olean` record of an install (`editorInstall`): the one relative
line `lib/lean` (`Editor/ModuleLookup.lean`, "The record"), so the
directory can be renamed into place. -/
def installOleansRecord : String :=
  "lib/lean\n"

/-- Why `editorInstall` refuses the directory `named` names (`installDirVar`),
with `present` whether it is there: an unset variable, and a directory that
is there; none for one that is not. -/
def installRefusal? (named : Option String) (present : Bool) : Option String :=
  match named with
  | none =>
    some
      s!"{installDirVar} must name the directory to install the editor into, which must not exist yet"
  | some dir =>
    if present then
      some s!"{dir} already exists: the editor is installed only into a directory that does not"
    else none

/-- The command `editorInstall` signs the copied executable `exe` with, on
macOS (`isOSX`): an ad-hoc signature, as `editorApp` signs the bundle;
none elsewhere, where the copy keeps the linker's. -/
def installSigning (isOSX : Bool) (exe : FilePath) : Option (String × Array String) :=
  if isOSX then some ("/usr/bin/codesign", #["--force", "--sign", "-", exe.toString]) else none

/-- A set's editor installed into one directory of its own, for a user's
package set (`EDITOR_INSTALL_DIR=<dir> lake -d <set dir> build
:editorInstall`; `docs/design/packages.md`, "User package sets"). It builds
the set's editor (`editor`), then fills `<dir>`, which must not exist yet:

- `editor`, a copy of the executable, signed ad hoc on macOS (as
  `editorApp` signs the bundle; the copy's signature is the linker's
  otherwise);
- `editor.core`, `editor.build` and `editor.coredir`, copies of the
  records beside it;
- `lib/lean/`, the `.olean`, `.olean.server` and `.olean.private` files of
  every module of the workspace the set's root imports
  (its `transImports`), from the directory each was built in;
- `editor.oleans`, the one relative line `lib/lean`
  (`Editor/ModuleLookup.lean`, "The record"), so `<dir>` can be renamed
  into place afterwards;
- `grammars/<lake>/`, a copy of each grammars directory the set's build
  staged (`editorGrammars`), compiled libraries included, and
  `editor.grammars`, one relative line for
  each (`installGrammarsRecord`; `Editor/ModuleLookup.lean`, "The
  grammars"), so the installed editor finds its packages' grammars beside
  it, for the reason the `.olean` files are copied;
- `libraries/<lake>/<file>`, a copy of each library the set's build staged
  (`editorLibraries`), and `editor.libraries`, one relative line for each
  (`installLibrariesRecord`; `Editor/ModuleLookup.lean`, "The
  libraries"), so the installed editor's packages load their libraries
  from beside it, after the packages' source directories and the set's
  build are gone.

The modules are copied, not referenced, so a later build that rewrites a
package's `.olean` files leaves this editor's modules matching its linked
code. The toolchain's own modules stay in the toolchain. It prints the
directory it filled. -/
package_facet editorInstall pkg : FilePath := do
  let exeJob ← fetch <| pkg.facet `editor
  let root ← setRoot pkg
  let importsJob ← root.transImports.fetch
  let grammarsJob ← (pkg.facet `editorGrammars).fetch
  let librariesJob ← (pkg.facet `editorLibraries).fetch
  (((exeJob.zipWith Prod.mk importsJob).zipWith Prod.mk librariesJob).zipWith Prod.mk
          grammarsJob).mapM
      fun (((exe, imports), libraryLines), grammarLines) => do
      let grammars := stagedLibrariesOf grammarLines
      let named ← IO.getEnv installDirVar
      let present ←
        match named with
        | some dir =>
          FilePath.pathExists dir
        | none =>
          pure false
      if let some reason := installRefusal? named present then
        error reason
      let dir : FilePath := named.getD ""
      let modules := dir / "lib" / "lean"
      IO.FS.createDirAll modules
      IO.FS.writeBinFile (dir / "editor") (← IO.FS.readBinFile exe)
      IO.setAccessRights (dir / "editor")
          { user := { read := true, write := true, execution := true }
            group := { read := true, execution := true }
            other := { read := true, execution := true } }
      for record in [".core", ".build", ".coredir"] do
        IO.FS.writeFile (dir / s!"editor{record}") (← IO.FS.readFile (exe.toString ++ record))
      for mod in imports do
        for kind in ["olean", "olean.server", "olean.private"] do
          let source := mod.leanLibPath kind
          if ← source.pathExists then
            let copy := Lean.modToFilePath modules mod.name kind
            if let some parent := copy.parent then
              IO.FS.createDirAll parent
            IO.FS.writeBinFile copy (← IO.FS.readBinFile source)
      IO.FS.writeFile (dir / "editor.oleans") installOleansRecord
      for (lake, staged) in grammars do
        copyTree staged (dir / "grammars" / lake)
      IO.FS.writeFile (dir / "editor.grammars") (installGrammarsRecord (grammars.map (·.1)))
      let mut installed : Array (String × String) := #[]
      for (lake, staged) in stagedLibrariesOf libraryLines do
        let some file := staged.fileName
          | error s!"the staged library of {lake} names no file: {staged}"
        let copy := dir / stagedLibraryPlace lake file
        if let some parent := copy.parent then
          IO.FS.createDirAll parent
        IO.FS.writeBinFile copy (← IO.FS.readBinFile staged)
        installed := installed.push (lake, file)
      IO.FS.writeFile (dir / "editor.libraries") (installLibrariesRecord installed)
      if let some (cmd, args) := installSigning Platform.isOSX (dir / "editor") then
        proc (quiet := true) { cmd, args }
      return dir

/- Guards: the install (`editorInstall`). Its `.olean` record is the one
relative line `lib/lean` (`installOleansRecord`), so the directory can be
renamed into place; it refuses an unset variable and a directory that is
there, naming why (`installRefusal?`), and takes one that is not; and on
macOS, and there only, it signs the copied executable ad hoc
(`installSigning`). Whether codesign accepts the result is codesign's. -/
#guard installOleansRecord == "lib/lean\n"

#guard
  installRefusal? none false ==
    some
      "EDITOR_INSTALL_DIR must name the directory to install the editor into, which must not exist yet"

#guard
  installRefusal? (some "/d/v") true ==
    some "/d/v already exists: the editor is installed only into a directory that does not"

#guard installRefusal? (some "/d/v") false == none

#guard
  installSigning true "/d/v/editor" ==
    some ("/usr/bin/codesign", #["--force", "--sign", "-", "/d/v/editor"])

#guard installSigning false "/d/v/editor" == none

/-- The root module of a package set, written and not built:
`lake -d <set dir> query :editorRoot` writes
`<set>/.lake/build/root/EditorSetRoot.lean` when its text would change
(`setRoot`) and prints its path. It links nothing and builds no module.

It is the generator of the package-set build on its own, for a link that
is not Lake's, so that such a link's root is generated as the editor's is
and written by no one. -/
package_facet editorRoot pkg : FilePath := do
  let root ← setRoot pkg
  return Job.pure root.leanFile

/-- The direct imports of a set's root module, one module a line
(`lake -d <set dir> query :editorRootImports`): the config base, the
executable's entry and the set's entry modules, as the workspace resolves
them. No library declares the root, so `lake query +<module>:imports` does
not find it; the gate pins it with this instead (`mise run ffi-test`). It
writes the root when its text would change and builds nothing. -/
package_facet editorRootImports pkg : Array String := do
  let root ← setRoot pkg
  (← root.imports.fetch).mapM fun modules => return modules.map (·.name.toString)

/-- The config base of a package set, one module a line
(`lake -d <set dir> query :editorBase`; `setBase`): `Editor`, then the
entry module of each package of the set outside the core. It is what the
generated root hands `Editor.Main.run`, and what `mise run module-bench`
takes the closure of. It reads no source and builds nothing. -/
package_facet editorBase pkg : Array String := do
  return Job.pure ((setBase (← setEntries pkg)).map (·.toString))

/-- The name of the fixture support module of the Lake package whose base
name is `baseName`: `<P>Test.FixtureSupport`, `<P>` the name in upper camel
case, a module of its test library, as its linked test is
(`linkedTestModule?`; `agents-api` gives `AgentsApiTest.FixtureSupport`). It
declares `support : Editor.Test.Fixture.Support`: the setups and the
service fakes the package's headless fixtures need on the stepped harness,
which the core cannot name (`Editor/Test/Fixture/Support.lean`). -/
def fixtureSupportModuleName (baseName : Name) : Name :=
  match toUpperCamelCase baseName with
  | .str namespace_ base => .str (.str namespace_ (base ++ "Test")) "FixtureSupport"
  | other => other ++ `FixtureSupport

/-- The fixture support module of `pkg` (`fixtureSupportModuleName`), when a
library of `pkg` holds it and its source file exists, as an entry module is
found (`entryModule?`). Lake is asked, and no source is read. -/
def fixtureSupportModule? (pkg : Package) : IO (Option Module) := do
  match pkg.findModule? (fixtureSupportModuleName pkg.baseName) with
  | some mod =>
    if ← mod.leanFile.pathExists then
      return some mod
    else
      return none
  | none =>
    return none

/-- The fixture support modules of the set `pkg`, in the order its packages
register (`setPackages`). -/
def setFixtureSupports (pkg : Package) : FetchM (Array Name) := do
  let ws ← getWorkspace
  let mut found := #[]
  for dep in setPackages ws pkg do
    match ← fixtureSupportModule? dep with
    | some mod =>
      found := found.push mod.name
    | none =>
      pure ()
  return found

/-- The text of a set's fixture harness's root module, for the entry
modules `entries` in the order they register, the entry modules `schemes`
that supply an input scheme, the config base `base` and the fixture
support modules `supports` of the set's packages, in the order they
register (`setFixtureSupports`), as `rootSource` writes the editor's: it
imports the core's base, `Editor`, for the link, then the harness's edge,
then each entry module and each support module; and its `main` is one call
of `Editor.Test.Fixture.Main.run` with the entry modules' `packages`
appended in that order, their `scheme`s, the base as an array of names,
and the support modules' `support`s. The editor's root imports no support
module, so no fake is linked into an editor. -/
def fixturesRootSource (entries schemes base supports : Array Name) : String :=
  let imports := (entries ++ supports).foldl (fun text name => text ++ s!"import {name}\n") ""
  let brought := ", ".intercalate (supports.map fun name => s!"{name}.support").toList
  let lists :=
    if entries.isEmpty then "#[]"
    else " ++ ".intercalate (entries.map fun name => s!"{name}.packages").toList
  let supplied := ", ".intercalate (schemes.map fun name => s!"{name}.scheme").toList
  let names := ", ".intercalate (base.map fun name => s!"`{name}").toList
  s!"import Editor
import Editor.Test.Fixture.Main
{imports}
/-!
# The fixture harness's root, generated

Written by the package-set build (`fixturesRoot` in `lean/lakefile.lean`)
from the Lake packages of a package set, as the editor's root is. Do not
edit it: the build writes it again.
-/

/-- The set's headless fixture harness (`Editor/Test/Fixture/Main.lean`),
with the packages of the set's Lake packages, the input schemes they
supply and the modules config is elaborated on, as the set's editor has
them, and the fixture supports the set's Lake packages declare. -/
def main (args : List String) : IO UInt32 :=
  Editor.Test.Fixture.Main.run ({lists}) #[{supplied}] #[{names}] #[{brought}] args
"

/- Guards: the fixture harness's root (`fixturesRootSource`). With no
package's fixture support it hands the harness none, and the core's setups
alone are its; with two it imports them after the entry modules, in order,
and hands their `support`s in that order. A package's fixture support
module is `<P>Test.FixtureSupport`, `<P>` its name in upper camel case. -/
#guard
  holdsText (fixturesRootSource #[] #[] #[`Editor] #[])
    "Editor.Test.Fixture.Main.run (#[]) #[] #[`Editor] #[] args"

#guard
  holdsText
    (fixturesRootSource #[`A.EditorPackage] #[] #[`Editor, `A.EditorPackage]
      #[`ATest.FixtureSupport, `BTest.FixtureSupport])
    "import A.EditorPackage\nimport ATest.FixtureSupport\nimport BTest.FixtureSupport\n"

#guard
  holdsText
    (fixturesRootSource #[`A.EditorPackage] #[] #[`Editor, `A.EditorPackage]
      #[`ATest.FixtureSupport, `BTest.FixtureSupport])
    "Editor.Test.Fixture.Main.run (A.EditorPackage.packages) #[] #[`Editor, `A.EditorPackage] #[ATest.FixtureSupport.support, BTest.FixtureSupport.support] args"

#guard fixtureSupportModuleName `workspace == `WorkspaceTest.FixtureSupport

#guard fixtureSupportModuleName `«agents-api» == `AgentsApiTest.FixtureSupport

/-- The name of the root module of a set's fixture harness. No library
declares it. -/
def fixturesRootName : Name :=
  `EditorSetFixtures

/-- The root module of the fixture harness of the set `pkg`
(`fixturesRootSource`), with the fixture support modules of the set's
packages in the order they register (`setFixtureSupports`), written to
`<set>/.lake/build/root/EditorSetFixtures.lean` beside the editor's root,
only when its text would change, a module of the library
`EditorSetFixtures` (`generatedLib`), as `setRoot` writes the editor's. -/
def fixturesRoot (pkg : Package) : FetchM Module := do
  let entries ← setEntries pkg
  let root : Module := { lib := generatedLib pkg `EditorSetFixtures, name := fixturesRootName }
  writeIfChanged root.leanFile
      (fixturesRootSource (entries.map (·.module)) ((entries.filter (·.scheme)).map (·.module))
        (setBase entries) (← setFixtureSupports pkg))
  return root

/-- The headless fixture harness of a package set:
`lake -d <set dir> build :editorFixtures` gives
`<set>/.lake/build/bin/fixture-test` (`docs/dev-practices/headless-mode.md`,
"How the gate runs a fixture"). A fixture's output depends on the set's
packages, input scheme and config base, which are compiled into the
executable, so each set has its own: its root (`fixturesRoot`) hands them
to `Editor.Test.Fixture.Main.run`, which runs the set's fixtures on the
stepped host with the fakes. It is linked as the editor is
(`linkAsEditor`: the glue, the core's Rust archive), and beside it the
build records where the `.olean` files of the set's packages are
(`writeModuleRecord`), so it finds the modules of its base as the editor
does. The shipped editor links none of it. -/
package_facet editorFixtures pkg : FilePath := do
  let executable := pkg.binDir / "fixture-test"
  writeModuleRecord pkg executable
  linkAsEditor pkg (← fixturesRoot pkg) executable

/-- The place under the bundle's `Contents/Resources/lean` of the Lake
package whose directory, with its links resolved, is `dir`, for a set whose
directory is `setDir` and a core whose directory is `coreDir`, both
resolved too: the core at `lean`, the set at `set` and a package under the
set's directory at the same place under `set`; none for a package
elsewhere, which the bundle cannot ship (`editorShipped`). -/
def shippedPlace (coreDir setDir dir : String) : Option String :=
  if dir == coreDir then some "lean"
  else
    if dir == setDir then some "set"
    else
      if dir.startsWith (setDir ++ "/") then
        some ("set/" ++ (dir.drop (setDir.length + 1)).toString)
      else none

#guard shippedPlace "/r/lean" "/r/packages" "/r/lean" == some "lean"

#guard shippedPlace "/r/lean" "/r/packages" "/r/packages" == some "set"

#guard shippedPlace "/r/lean" "/r/packages" "/r/packages/compile" == some "set/compile"

#guard shippedPlace "/r/lean" "/r/packages" "/r/packages-other" == none

#guard shippedPlace "/r/lean" "/r/packages" "/elsewhere/p" == none

/-- `file` relative to `dir`, when `file` is under it, with every `.`
part left out: `dir` and `file` as Lake builds them, one by joining parts
to the other. -/
def relativeUnder (dir file : FilePath) : Option String :=
  let prefix_ := dir.toString ++ "/"
  if file.toString.startsWith prefix_ then
    let parts := ((file.toString.drop prefix_.length).toString.splitOn "/").filter (· != ".")
    some ("/".intercalate parts)
  else none

#guard relativeUnder "/r/lean" "/r/lean/./Editor/Api.lean" == some "Editor/Api.lean"

#guard relativeUnder "/r/lean" "/r/other/Api.lean" == none

/-- The interface libraries staged in the core's Lake package, each with its
test library (`lean_lib FilesApi`, `lean_lib EnvironmentApi`, above): the
config base imports them, `FilesApi` through the features still in the core
and `EnvironmentApi` for config's sources, so the bundle ships them as it
ships `Editor`. One moves out of this list when it moves to `packages/`, as
`VcApi` and `ProjectApi` did in phase 6. -/
def stagedInterfaceLibraries : List Lean.Name :=
  [`FilesApi, `FilesApiTest, `EnvironmentApi, `EnvironmentApiTest]

/-- `shipsLibrary` on names: whether the library `libName` of a package
whose base name is `baseName`, the core when `isCore`, ships. -/
def shipsLibraryNamed (isCore : Bool) (baseName libName : Name) : Bool :=
  if isCore then libName == `Editor || libName == `Lint || stagedInterfaceLibraries.contains libName
  else
    match toUpperCamelCase baseName with
    | .str namespace_ base => libName != .str namespace_ (base ++ "Test")
    | _ => true

/-- Whether a library of `pkg` ships its modules built in the bundle
(`editorShipped`): of the core, `Editor`, the library
`coreIdentity` reads, the interface libraries staged in it
(`stagedInterfaceLibraries`), whose changes reach the identity through the
traces of the core's modules that import them, and the build's linters,
`Lint`, which every library of a set loads as a plugin (`lintPlugin`), so
the plugin's trace is in every module's and a build from the bundle needs
it built to read them as up to date; of another package, each library but
its tests, `<P>Test`. -/
def shipsLibrary (pkg : Package) (lib : LeanLib) : Bool :=
  shipsLibraryNamed (pkg.keyName == __name__) pkg.baseName lib.name

/- Guards: which libraries the bundle ships (`shipsLibraryNamed`): of the
core, `Editor`, the linters' `Lint` and the staged interface libraries
`FilesApi`, `FilesApiTest`, `EnvironmentApi` and `EnvironmentApiTest`, and
none of its test libraries; of another
package, each library but its tests, `<P>Test`. -/
#guard
  [`Editor, `Lint, `FilesApi, `FilesApiTest, `EnvironmentApi, `EnvironmentApiTest].all
    (shipsLibraryNamed true `«editor-core» ·)

#guard
  ![`ModelTests, `ConfigFixture, `InterpretedFixture].any (shipsLibraryNamed true `«editor-core» ·)

#guard shipsLibraryNamed false `compile `Compile

#guard !shipsLibraryNamed false `compile `CompileTest

#guard !shipsLibraryNamed false `«shipped-themes» `ShippedThemesTest

/-- Every module of the library `lib` whose source file is there: its
modules (`LeanLib.modules`) and each module under the directory of one of
its roots, so a module no root imports is among them too, since a package
may import any of them. -/
def libraryModules (lib : LeanLib) (listed : Array Module) : IO (Array Module) := do
  let mut found := listed
  for root in lib.roots do
    let dir :=
      root.components.foldl (fun dir part => dir / part.toString (escape := false)) lib.srcDir
    if ← dir.isDir then
      for path in ← dir.walkDir do
        if path.extension == some "lean" then
          if let some relative := relativeUnder lib.srcDir path then
            let name :=
              ((relative.dropEnd ".lean".length).toString.splitOn "/").foldl
                (fun name part => Name.str name part) Name.anonymous
            if let some mod := lib.findModule? name then
              found := found.push mod
  let mut seen : Std.HashSet Name := {}
  let mut modules : Array Module := #[]
  for mod in found do
    if !seen.contains mod.name && (← mod.leanFile.pathExists) then
      seen := seen.insert mod.name
      modules := modules.push mod
  return modules

/-- Of a directory's `entries`, the files Lake wrote for a module whose
last part is the stem, `stem` being that part and a dot: every entry whose
name starts with it, in order of their paths (`builtFiles`). -/
def builtOf (stem : String) (entries : Array IO.FS.DirEntry) : Array FilePath :=
  ((entries.filter (·.fileName.startsWith stem)).map (·.path)).qsort (·.toString < ·.toString)

/-- The files of the built module `mod` in its package's build directory:
every file in the directory of its `.olean` and in that of its C file
whose name is the module's last part and an ending (`Api.olean`,
`Api.olean.hash`, `Api.trace`, `Api.c.o.export`, `Api.setup.json` and the
rest), whatever Lake wrote, so Lake reads the copy as up to date. -/
def builtFiles (mod : Module) : IO (Array FilePath) := do
  let stem := mod.name.getString! ++ "."
  let mut files : Array FilePath := #[]
  for dir in [mod.oleanFile.parent, mod.cFile.parent] do
    let some dir := dir | continue
    if ← dir.isDir then
      files := files ++ builtOf stem (← dir.readDir)
  return files

/- Guards: the files Lake wrote for a module that the bundle ships, of a
directory's entries (`builtOf`): every one named the module's last part and
an ending, in order, and none of another module whose name only starts the
same. -/
#guard
  builtOf "Api."
      #[{ root := "/b", fileName := "Api.trace" }, { root := "/b", fileName := "ApiX.olean" },
        { root := "/b", fileName := "Api.olean" }, { root := "/b", fileName := "Api.c.o.export" },
        { root := "/b", fileName := "Api.olean.hash" }] ==
    (#["/b/Api.c.o.export", "/b/Api.olean", "/b/Api.olean.hash", "/b/Api.trace"] : Array FilePath)

/-- The line `editorShipped` lists for the file `file` of the package at
`dir`, copied from `source`, its package at `place`: `file<TAB><source><TAB>
<place>/<file relative to dir>`; none for a file that is not under
`dir`. -/
def shippedFileLine (dir file source : FilePath) (place : String) : Option String :=
  (relativeUnder dir file).map fun relative => s!"file\t{source}\t{place}/{relative}"

/-- Whether `editorShipped` lists a package's file `file` by the file it
resolves to: its `lean-toolchain`, which in this repository is a link to
the core's pin that would dangle in the bundle. -/
def listsResolved (file : FilePath) : Bool :=
  file.fileName == some "lean-toolchain"

/-- The `oleans` lines `editorShipped` lists for the set's `.olean`
directories `directories`, in order (`moduleDirectories`), with `placed`
each package's directory, `.olean` directory and place: each directory
under the bundle's `lean` at its package's place; an error for a
directory of no package of the set, or not under its package's. -/
def shippedOleansLines (directories : Array FilePath)
    (placed : Array (FilePath × FilePath × String)) : Except String (Array String) :=
  directories.mapM fun directory => do
    let some (dir, _, place) := placed.find? fun (_, libDir, _) => libDir == directory
      | throw s!"the .olean directory {directory} is of no package of the set"
    let some relative := relativeUnder dir directory
      | throw s!"{directory} is not under its package's directory {dir}"
    return s!"oleans\tlean/{place}/{relative}"

/-- The lines `editorShipped` lists for the grammars directory of the Lake
package `lake` whose directory is `dir`, which the set's build staged at
`staged` (`editorGrammars`), for its place `place`: the package's own
`grammars/`, copied whole to `<place>/grammars`; then each file of the
staged directory the package's own does not hold, `compiled`, each a path
relative to the staged directory (the libraries the set's build compiled
from source), copied to the same path under `<place>/grammars`, so the
bundled package ships them as a prebuilt one does and a user's set built
from the bundle compiles nothing; and the line
`grammars<TAB><lake><TAB><place>/grammars`, which the `stage-bundle`
binary writes into the bundle's record `editor.grammars`
(`Editor/ModuleLookup.lean`, "The grammars"). Each `file` line keeps its
source's name, which `stage-bundle` requires: so the staged directory,
named after its Lake package, is not listed whole. -/
def shippedGrammarsLines (lake : String) (dir staged : FilePath) (compiled : Array String)
    (place : String) : Array String :=
  #[s!"file\t{dir / "grammars"}\t{place}/grammars"] ++
    compiled.map
      (fun (relative : String) => s!"file\t{staged / relative}\t{place}/grammars/{relative}") ++
    #[s!"grammars\t{lake}\t{place}/grammars"]

/- Guards: the grammars lines (`shippedGrammarsLines`): a prebuilt package's
own `grammars/` copied to its place's `grammars`, and the record's line
naming the Lake package and that place; and a package whose grammar the
set's build compiled, its library listed from the staged directory to the
same path under its place's `grammars`, between the two. -/
#guard
  shippedGrammarsLines "ini-grammar" "/r/tests/grammar-set/ini-grammar"
      "/r/tests/grammar-set/.lake/build/grammars/ini-grammar" #[] "set/ini-grammar" ==
    #["file\t/r/tests/grammar-set/ini-grammar/grammars\tset/ini-grammar/grammars",
      "grammars\tini-grammar\tset/ini-grammar/grammars"]

#guard
  shippedGrammarsLines "languages" "/r/packages/languages"
      "/r/packages/.lake/build/grammars/languages" #["darwin-aarch64/libtree-sitter-yaml.dylib"]
      "set/languages" ==
    #["file\t/r/packages/languages/grammars\tset/languages/grammars",
      "file\t/r/packages/.lake/build/grammars/languages/darwin-aarch64/libtree-sitter-yaml.dylib\tset/languages/grammars/darwin-aarch64/libtree-sitter-yaml.dylib",
      "grammars\tlanguages\tset/languages/grammars"]

/-- The files under the directory `staged`, each as a path relative to it
with `/` between its parts, that the directory `own` does not hold at the
same path: what a set's build added to a staged grammars directory over
the package's own (`shippedGrammarsLines`), in the order the directories
list them. -/
partial def filesNotIn (staged own : FilePath) (under : String := "") : IO (Array String) := do
  let mut found : Array String := #[]
  for entry in ← (if under.isEmpty then staged else staged / under).readDir do
    let relative := if under.isEmpty then entry.fileName else s!"{under}/{entry.fileName}"
    if ← entry.path.isDir then
      found := found ++ (← filesNotIn staged own relative)
    else
      unless ← (own / relative).pathExists do
        found := found.push relative
  return found

/- Guards: the lines `editorShipped` lists. A package's file goes to its
place under the package's (`shippedFileLine`), its `lean-toolchain` among
them, listed by the file it resolves to (`listsResolved`), so the bundle
holds the pin's text where the checkout holds a link; and the `oleans`
lines are the set's `.olean` directories in order, the core's first, each
under the bundle's `lean` at its package's place (`shippedOleansLines`),
and a directory of no package of the set is an error. -/
#guard
  shippedFileLine "/r/packages/compile" "/r/packages/compile/lean-toolchain"
      "/r/lean/lean-toolchain" "set/compile" ==
    some "file\t/r/lean/lean-toolchain\tset/compile/lean-toolchain"

#guard
  shippedFileLine "/r/packages/compile" "/r/other/lean-toolchain" "/r/lean/lean-toolchain" "set" ==
    none

#guard listsResolved "/r/packages/compile/lean-toolchain"

#guard !listsResolved "/r/packages/compile/lakefile.toml"

#guard
  (shippedOleansLines #["/r/lean/.lake/build/lib/lean", "/r/packages/compile/.lake/build/lib/lean"]
        #[("/r/lean", "/r/lean/.lake/build/lib/lean", "lean"),
          ("/r/packages/compile", "/r/packages/compile/.lake/build/lib/lean",
            "set/compile")]).toOption ==
    some
      #["oleans\tlean/lean/.lake/build/lib/lean", "oleans\tlean/set/compile/.lake/build/lib/lean"]

#guard
  (shippedOleansLines #["/elsewhere/lib"] #[("/r/lean", "/r/lean/lib", "lean")]).toOption.isNone

/-- What an app bundle ships of the set `pkg`, built (`lake -d <set dir>
query :editorShipped`; `docs/design/lean-runtime.md`, "Build"), so a
user's package-set build from the bundle compiles nothing of it: one line
`file<TAB><source><TAB><place>` for each file, its place relative to the
bundle's `Contents/Resources/lean`, and one line `oleans<TAB><place>` for
each `.olean` directory of the set (`moduleDirectories`), in order, its
place relative to `Contents/Resources`, which the bundle's record
`editor.oleans` holds (`Editor/ModuleLookup.lean`, "The bundle's record").
For each package that ships grammars (`grammarsKeyword`), its `grammars/`
directory, copied whole to its place's `grammars`, with each library the
set's build compiled into its staged directory (`editorGrammars`, which it
fetches; `filesNotIn`) copied beside, and one line
`grammars<TAB><lake><TAB><place>` (`shippedGrammarsLines`), which the
bundle's record `editor.grammars` holds (`Editor/ModuleLookup.lean`, "The
grammars").

The core goes to `lean`, the set to `set` and each package under the set's
directory to the same place under `set` (`shippedPlace`), so the set's and
the packages' lakefiles name the bundle's core unchanged; a package
elsewhere is refused. For each package of the set (`setPackages`): its
lakefile, `lake-manifest.json` and `lean-toolchain`, the last listed by
the file it resolves to, since a package's in this repository is a link to
the pin (`lean/lean-toolchain`) that would dangle in the bundle, which so
holds its text; and for every module
of each library that ships (`shipsLibrary`, `libraryModules`: of the core,
`Editor` and `Lint`; of the others, each library but its tests), its
source and every file Lake wrote for it (`builtFiles`), and of `Lint` its
plugin, the shared library and every file Lake wrote beside it. Of the core, also
its glue, `ffi/glue.c`, with `glue.o` built and its trace and hash. Then
the core's Rust archive and its system libraries
(`prebuiltRustFiles`), at `target/` under `lean`, which is where a user's
set outside the bundle's `lean` reads them (`prebuiltRust`,
`repositoryRoot`).

It fetches each listed module's `oExport`, and so its `.olean`, `.ilean`
and C file, and `glue.o`, so every file it lists is built. It builds no
Rust: the archive must be built already. The `stage-bundle` binary
(`stageBundle`) copies what it lists and decides nothing; which modules exist is Lake's
knowledge, and a module left out would be built into the bundle the first
time a package imported it. -/
package_facet editorShipped pkg : Array String := do
  let ws ← getWorkspace
  let some core := ws.findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  let coreDir := (← IO.FS.realPath core.dir).toString
  let setDir := (← IO.FS.realPath pkg.dir).toString
  let mut placed : Array (Package × String) := #[]
  let mut libraries : Array (Job (Array Module)) := #[]
  let mut plugins : Array (Job Dynlib) := #[]
  for dep in setPackages ws pkg do
    let dir := (← IO.FS.realPath dep.dir).toString
    let some place := shippedPlace coreDir setDir dir
      |
      error
          s!"the package {dep.baseName.toString (escape := false)} ({dir}) is outside the set's directory {setDir}, so an app bundle cannot ship it"
    placed := placed.push (dep, place)
    for lib in dep.leanLibs do
      if shipsLibrary dep lib then
        libraries :=
          libraries.push (← (← lib.modules.fetch).mapM fun listed => libraryModules lib listed)
      if dep.keyName == __name__ && lib.name == `Lint then
        plugins := plugins.push (← lib.shared.fetch)
  let directories ← moduleDirectories pkg
  let glueJob ← glue.o.fetch
  let root ← repositoryRoot
  let modulesJob := (Job.collectArray libraries).map (·.flatten)
  let builtJob ←
    modulesJob.bindM fun modules => do
        let jobs ← modules.mapM (·.oExport.fetch)
        return (Job.collectArray jobs).map fun _ => modules
  let pluginsJob := Job.collectArray plugins
  let grammarsJob ← (pkg.facet `editorGrammars).fetch
  (((builtJob.zipWith Prod.mk glueJob).zipWith Prod.mk pluginsJob).zipWith Prod.mk grammarsJob).mapM
      fun (((modules, _), dynlibs), grammarLines) => do
      let stagedGrammarsOf := stagedLibrariesOf grammarLines
      let placeOf (dep : Package) : Option String :=
        (placed.find? (·.1.keyName == dep.keyName)).map (·.2)
      let mut lines : Array String := #[]
      let line (source : FilePath) (place : String) : String := s!"file\t{source}\t{place}"
      for (dep, place) in placed do
        for file in [dep.configFile, dep.dir / "lake-manifest.json", dep.dir / "lean-toolchain"] do
          if ← file.pathExists then
            let source ←
              if listsResolved file then
                IO.FS.realPath file
              else
                pure file
            let some listed := shippedFileLine dep.dir file source place
              | error s!"{file} is not under its package's directory {dep.dir}"
            lines := lines.push listed
        if dep.keywords.contains grammarsKeyword then
          let lake := dep.baseName.toString (escape := false)
          let some (_, staged) := stagedGrammarsOf.find? (·.1 == lake)
            | error s!"the set's build staged no grammars directory for {lake}"
          let own ← IO.FS.realPath dep.dir
          lines :=
            lines ++
              shippedGrammarsLines lake own staged (← filesNotIn staged (own / "grammars")) place
      let gluePlace := placeOf core
      for file in
        [core.dir / "ffi" / "glue.c", core.buildDir / "ffi" / "glue.o",
          core.buildDir / "ffi" / "glue.o.hash", core.buildDir / "ffi" / "glue.o.trace"] do
        let some relative := relativeUnder core.dir file
          | error s!"{file} is not under the core's directory {core.dir}"
        if let some place := gluePlace then
          lines := lines.push (line file s!"{place}/{relative}")
      for mod in modules do
        let some place := placeOf mod.pkg
          | error s!"the module {mod.name} is of no package of the set"
        for file in #[mod.leanFile] ++ (← builtFiles mod) do
          let some relative := relativeUnder mod.pkg.dir file
            | error s!"{file} is not under its package's directory {mod.pkg.dir}"
          lines := lines.push (line file s!"{place}/{relative}")
      for dynlib in dynlibs do
        let some dir := dynlib.path.parent | error s!"{dynlib.path} has no directory"
        let some stem := dynlib.path.fileName | error s!"{dynlib.path} has no file name"
        let some place := gluePlace | error "the core's package is of no place in the set"
        let entries := (← dir.readDir).filter (·.fileName.startsWith stem)
        for file in (entries.map (·.path)).qsort (·.toString < ·.toString) do
          let some relative := relativeUnder core.dir file
            | error s!"{file} is not under the core's directory {core.dir}"
          lines := lines.push (line file s!"{place}/{relative}")
      let (archive, libraries) := prebuiltRustFiles root
      for file in [archive, libraries] do
        let some relative := relativeUnder root file
          | error s!"{file} is not under the repository {root}"
        lines := lines.push (line file relative)
      match
        shippedOleansLines directories
          (placed.map fun (dep, place) => (dep.dir, dep.leanLibDir, place)) with
      | .ok oleans =>
        lines := lines ++ oleans
      | .error message =>
        error message
      return lines

/-- The file of the executable `editorLinked` links for the module `mod`:
in the `bin/` of the module's package, named as the module is with a dash
for each dot (`GreetingTest.Linked` gives `GreetingTest-Linked`). -/
def linkedFile (mod : Module) : FilePath :=
  mod.pkg.binDir / mod.name.toStringWithSep "-" (escape := false)

/-- An executable rooted at a module, linked as the editor is
(`linkAsEditor`), at `linkedFile`: `lake -d <package> build
+<module>:editorLinked`. It is how a package outside the core gets a test
executable linked with the glue and the Rust archive, which only this
package can name (`linkedTestModule?`, `tools/package-set.sh`). -/
module_facet editorLinked mod : FilePath := do
  linkAsEditor mod.pkg mod (linkedFile mod)

/-- The module of the linked test of the Lake package `pkg`, when it has
one: `<P>Test.Linked`, `<P>` being the package's name in upper camel case,
held by a library of `pkg`, with its source file. It is the root of one
executable linked as the editor is (`editorLinked`): the tests of a package
that need the Rust library, as `ffi-test` and `config-test` are the
core's. -/
def linkedTestModule? (pkg : Package) : IO (Option Module) := do
  let .str namespace_ base := toUpperCamelCase pkg.baseName | return none
  match pkg.findModule? (.str (.str namespace_ (base ++ "Test")) "Linked") with
  | some mod =>
    if ← mod.leanFile.pathExists then
      return some mod
    else
      return none
  | none =>
    return none

/-- The packages of a set that a step of the gate runs over
(`tools/package-set.sh`; `lake -d <set dir> query :editorPackages`): the
packages of the set (`setPackages`) that are path dependencies and hold a
Lean library, other than this one, the core, which the gate's own tasks
cover. One line a package, its fields separated by tabs: its name, its
directory, the module of its linked test (`linkedTestModule?`) and the
executable `editorLinked` links for it, the last two `-` for a package with
no linked test. -/
package_facet editorPackages pkg : Array String := do
  let ws ← getWorkspace
  let mut lines : Array String := #[]
  for dep in setPackages ws pkg do
    if dep.keyName == __name__ || !dep.remoteUrl.isEmpty || dep.leanLibs.isEmpty then
      continue
    let linked :=
      match ← linkedTestModule? dep with
      | some mod => s!"{mod.name}\t{linkedFile mod}"
      | none => "-\t-"
    lines := lines.push s!"{dep.baseName.toString (escape := false)}\t{dep.dir}\t{linked}"
  return Job.pure lines

/-- The checks of the boundary with the Rust library (`FfiTest.lean`), linked
exactly like the editor (`linkAsEditor`): `supportInterpreter` exports the
executable's symbols, so interpreted config can find compiled definitions
and `@[extern]` symbols, and the glue, the Rust archive and `linkArgs` are
the same. `mise run ffi-test` runs it. -/
@[default_target] lean_exe «ffi-test» where
  root := `FfiTest
  plugins := lintPlugin
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs.push coreSystemLibraries

/-- The checks of the config session against the real elaborator
(`ConfigTest.lean`), linked exactly like the editor, as `ffi-test` is.
`mise run ffi-test` runs it. It also holds the benchmark `mise run config-bench` runs. -/
@[default_target] lean_exe «config-test» where
  root := `ConfigTest
  plugins := lintPlugin
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs.push coreSystemLibraries

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

/-- The bundle's `CFBundleExecutable`: the app's launcher (`launcher`), which
the `stage-bundle` binary (`stageBundle`) places at
`Contents/MacOS/leanmacs`. -/
def appExecutable : String :=
  "leanmacs"

/-- The app's name: the bundle's, `<name>.app`, and its icon's. -/
def appName : String :=
  "Leanmacs"

/-- The bundle identifier. The repository is leanmacs/leanmacs. -/
def appIdentifier : String :=
  "io.github.leanmacs.Leanmacs"

/-- The lowest macOS the bundle has been run on; lower it only after running
it there. The window was run by hand on 27.2 (2026-11-15). The owner chose
26.0 on 2026-11-17: CI's build job builds and checks the shipped image
(`mise run dmg-check`, its `editor --version`) on the `macos-26` runner
on every main build, and the owner
checks once that the nightly opens its window on a macOS 26 Mac
(docs/dev-practices/ci.md, "Deployment target"). It must equal
`MACOSX_DEPLOYMENT_TARGET` in mise.toml. -/
def appMinimumSystemVersion : String :=
  "26.0"

/-- The app's version file, relative to the core's directory: one line,
the version, which `editorApp` writes into `Info.plist`. -/
def appVersionFile : FilePath :=
  "app" / "version"

/-- The icon's artwork, relative to the core's directory: a 1024×1024
PNG, from which `editorApp` makes `Contents/Resources/Leanmacs.icns`. -/
def appIconFile : FilePath :=
  "app" / "Leanmacs.png"

/-- The version in the contents of the version file (`appVersionFile`): its
one line, less one trailing newline, which must be one to three
dot-separated runs of ASCII digits, the form `CFBundleShortVersionString`
takes. Anything else, a second line, whitespace or
an empty file among it, is an error naming the file and what it holds, so a
malformed version fails the build instead of making a bundle LaunchServices
misreads. -/
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
sets the variable. -/
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
instead of being stretched into a blurred icon. -/
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
with no dot in it, so `plutil -extract` can address it. `LeanmacsCoreTag`
is the tag of the build's core, `nightly-<build ID>`, which the nightly
release creates at the commit and a package pins the core at; it is
derived here from the build ID, and `editor-release`'s `core_tag` holds
it to its own derivation at release (`check_stamp`). `editor --version`
reads the four (`Editor/Version.lean`, `plistKeys`). `NSHumanReadableCopyright` names
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
\t<string>{appExecutable}</string>
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
\t<key>LeanmacsCoreTag</key>
\t<string>nightly-{build}</string>
\t<key>NSHighResolutionCapable</key>
\t<true/>
\t<key>NSHumanReadableCopyright</key>
\t<string>Licensed under GPL-3.0-or-later.</string>
</dict>
</plist>
"

/-- The images of the icon's `.iconset`, each with its size in pixels: the
ten standard ones, 16, 32, 128, 256 and 512 points at 1× and 2×.
`editorApp` makes each from the artwork (`appIconFile`) with `sips`. -/
def appIconSizes : List (String × Nat) :=
  [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)]

/-- The variable the lowest macOS the binaries are linked for is taken from
(`mise.toml`'s `[env]`), which their `minos` records. -/
def deploymentTargetVar : String :=
  "MACOSX_DEPLOYMENT_TARGET"

/-- Whether the version `given` is no later than `limit`, each a list of
its dot-separated numbers, a missing part being 0. -/
def versionAtMost : List Nat → List Nat → Bool
  | [], [] => true
  | [], limit :: rest => 0 < limit || (limit == 0 && versionAtMost [] rest)
  | given :: rest, [] => given == 0 && versionAtMost rest []
  | given :: rest, limit :: more => given < limit || (given == limit && versionAtMost rest more)

/-- Whether binaries linked for the deployment target `linked`, the value of
`deploymentTargetVar`, run on the bundle's `LSMinimumSystemVersion`,
`minimum`: the target must be set, a version, and no later than it;
anything else is an error naming the variable, so a bundle whose
binaries need a later macOS than it claims is never built. -/
def deploymentTargetFits (linked : Option String) (minimum : String) : Except String Unit := do
  let parse (text : String) : Option (List Nat) := (text.splitOn ".").mapM String.toNat?
  let some given := linked
    |
    throw
        s!"{deploymentTargetVar} must be the lowest macOS the binaries are linked for, no later than LSMinimumSystemVersion {minimum}, but is unset"
  let (some version, some limit) := (parse given, parse minimum)
    |
    throw
        s!"{deploymentTargetVar} must be a version no later than LSMinimumSystemVersion {minimum}, but holds {repr given}"
  unless versionAtMost version limit do
    throw
        s!"{deploymentTargetVar} is {given}, later than the bundle's LSMinimumSystemVersion {minimum}: the binaries would not run on every macOS the bundle claims"

/-- One step of assembling the app bundle (`appSteps`), which `editorApp`
runs in order. -/
inductive AppStep where
  /-- Runs the program `cmd` with `args`, failing the build if it fails. -/
  | run (cmd : String) (args : Array String)
  /-- Writes `text` as the file `file`. -/
  | write (file : FilePath) (text : String)
  /-- Makes the directory `dir` and those above it. -/
  | makeDirectory (dir : FilePath)
  /-- Moves the staged bundle into the bundle's place, by renames. -/
  | moveIntoPlace
  deriving BEq, Inhabited

/-- How `editorApp` assembles the bundle in `staging`, from the
`stage-bundle` binary `stager` (`stageBundle`), the launcher `launcher`,
the set's editor `exe`, the toolchain `sysroot`, the list of shipped files
`list`, the artwork `art` and the property list's text `plist`: the bundle staged, its `Info.plist` written,
its icon made from the artwork in an iconset beside it, its extended
attributes cleared, then the whole staged bundle signed, the last step
that touches it, since a write after the signature breaks the seal, and
then moved into place. -/
def appSteps (stager launcher exe sysroot list staging art : FilePath) (plist : String) :
    Array AppStep :=
  let staged := staging / s!"{appName}.app"
  let iconset := staging / s!"{appName}.iconset"
  #[.run stager.toString
        #["--launcher", launcher.toString, staged.toString, exe.toString, sysroot.toString,
          list.toString],
      .write (staged / "Contents" / "Info.plist") plist, .makeDirectory iconset] ++
    (appIconSizes.toArray.map fun (name, size) =>
      .run "/usr/bin/sips"
        #["-z", toString size, toString size, art.toString, "--out", (iconset / name).toString]) ++
    #[.run "/usr/bin/iconutil"
        #["-c", "icns", iconset.toString, "-o",
          (staged / "Contents" / "Resources" / s!"{appName}.icns").toString],
      .run "/usr/bin/xattr" #["-cr", staged.toString],
      .run "/usr/bin/codesign" #["--force", "--sign", "-", staged.toString], .moveIntoPlace]

/- Guards: the bundle's `Info.plist` (`appInfoPlist`). It holds the four
stamped values `editor --version` and the release read, the core's tag
derived from the build ID; exactly two document types, "Text" then "Any
file"; no `Owner` or `Default` rank and no type declarations; arm64 as
the architecture; the launcher, `appExecutable`, as `CFBundleExecutable`;
and `appMinimumSystemVersion` as `LSMinimumSystemVersion`. -/
#guard
  let plist := appInfoPlist "0.1.0" "20010203040506" "0123456789abcdef0123456789abcdef01234567"
  [("CFBundleShortVersionString", "0.1.0"), ("CFBundleVersion", "20010203040506"),
        ("LeanmacsCommit", "0123456789abcdef0123456789abcdef01234567"),
        ("LeanmacsCoreTag", "nightly-20010203040506"), ("CFBundleExecutable", appExecutable),
        ("LSMinimumSystemVersion", appMinimumSystemVersion)].all
    fun (key, value) => holdsText plist s!"<key>{key}</key>\n\t<string>{value}</string>\n"

#guard
  let plist :=
    appInfoPlist "0.1.0" "20010203040506" "0123456789abcdef0123456789abcdef01234567"
  (plist.splitOn "<key>CFBundleTypeName</key>\n\t\t\t<string>").drop 1 |>.map
      (·.takeWhile (· != '<') |>.toString) ==
    ["Text", "Any file"]

#guard
  let plist := appInfoPlist "0.1.0" "20010203040506" "0123456789abcdef0123456789abcdef01234567"
  !holdsText plist "<string>Owner</string>" && !holdsText plist "<string>Default</string>" &&
    !holdsText plist "TypeDeclarations" &&
    holdsText plist
      "<key>LSArchitecturePriority</key>\n\t<array>\n\t\t<string>arm64</string>\n\t</array>"

#guard appExecutable == "leanmacs"

/- Guards: the version file's line (`parseAppVersion`): one to three
dot-separated runs of digits, with or without one trailing newline; an
empty file, a fourth part, an empty part, a letter, a space or a second
line is an error naming the file. -/
#guard (parseAppVersion "0.1.0").toOption == some "0.1.0"

#guard (parseAppVersion "0.1.0\n").toOption == some "0.1.0"

#guard (parseAppVersion "1").toOption == some "1"

#guard
  ["", "\n", "0.1.0.1", "0..1", "v0.1", " 0.1", "0.1.0\n\n", "0.1\n2"].all fun text =>
    match parseAppVersion text with
    | .error message => message.startsWith "app/version must be one line"
    | .ok _ => false

/- Guards: the stamp (`parseAppStamp`): a build ID of 14 digits and a
commit of 40 lowercase hex digits is taken; each unset or malformed value
is an error that starts with its variable's name. -/
#guard
  (parseAppStamp (some "20010203040506")
        (some "0123456789abcdef0123456789abcdef01234567")).toOption ==
    some ("20010203040506", "0123456789abcdef0123456789abcdef01234567")

#guard
  [(none, some "0123456789abcdef0123456789abcdef01234567"),
        (some "2001020304050", some "0123456789abcdef0123456789abcdef01234567"),
        (some "2001020304050x", some "0123456789abcdef0123456789abcdef01234567")].all
    fun (build, commit) =>
    match parseAppStamp build commit with
    | .error message => message.startsWith appBuildIdVar
    | .ok _ => false

#guard
  [none, some "0123456789ABCDEF0123456789abcdef01234567", some "0123456789abcdef"].all fun commit =>
    match parseAppStamp (some "20010203040506") commit with
    | .error message => message.startsWith appCommitVar
    | .ok _ => false

/- Guards: the artwork (`checkAppArtwork`, over what `sips` prints): a
1024×1024 PNG is taken; another size or format, or nothing read, is an
error naming the file. -/
#guard
  (checkAppArtwork
        "/a/Leanmacs.png\n  pixelWidth: 1024\n  pixelHeight: 1024\n  format: png\n").toOption ==
    some ()

#guard
  ["  pixelWidth: 512\n  pixelHeight: 512\n  format: png\n",
        "  pixelWidth: 1024\n  pixelHeight: 768\n  format: png\n",
        "  pixelWidth: 1024\n  pixelHeight: 1024\n  format: jpeg\n", ""].all
    fun text =>
    match checkAppArtwork text with
    | .error message => message.startsWith "app/Leanmacs.png must be a 1024x1024 PNG"
    | .ok _ => false

/- Guards: the icon's images (`appIconSizes`): the ten standard names, each
once, each size following from its name, `icon_<n>x<n>.png` being n
pixels and `icon_<n>x<n>@2x.png` 2n. -/
#guard
  appIconSizes.map (·.1) ==
    ["icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
      "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png",
      "icon_512x512.png", "icon_512x512@2x.png"]

#guard
  appIconSizes.all fun (name, size) =>
    match
      ((name.dropPrefix? "icon_").map (·.toString.takeWhile (· != 'x') |>.toString)).bind
        String.toNat? with
    | some points => size == if holdsText name "@2x" then 2 * points else points
    | none => false

/- Guards: the deployment target (`deploymentTargetFits`): the binaries'
minimum macOS, `MACOSX_DEPLOYMENT_TARGET`, must be no later than the
bundle's `LSMinimumSystemVersion`, which `editorApp` checks before it
links; an unset one is refused, naming the variable. -/
#guard (deploymentTargetFits (some "26.0") "26.0").toOption == some ()

#guard (deploymentTargetFits (some "25") "26.0").toOption == some ()

#guard
  [some "26.1", some "27", none, some "x"].all fun linked =>
    match deploymentTargetFits linked "26.0" with
    | .error message => message.startsWith "MACOSX_DEPLOYMENT_TARGET"
    | .ok () => false

/- Guards: how `editorApp` assembles the bundle (`appSteps`, which the facet
runs in order). It stages the bundle, writes its `Info.plist` and makes
its icon; then clears extended attributes, then signs the whole staged
bundle, the last step that touches it, since a write after the signature
breaks the seal; and the renames into place come last. Whether `codesign`
accepts the bundle is codesign's. -/
#guard
  let steps :=
    appSteps "/t/stage-bundle" "/t/leanmacs" "/t/editor" "/t/sysroot" "/s/list" "/s/staging"
      "/c/app/Leanmacs.png" "<plist/>"
  steps[0]? ==
      some
        (.run "/t/stage-bundle"
          #["--launcher", "/t/leanmacs", "/s/staging/Leanmacs.app", "/t/editor", "/t/sysroot",
            "/s/list"]) &&
    steps.contains (.write "/s/staging/Leanmacs.app/Contents/Info.plist" "<plist/>") &&
    steps[steps.size - 3]? == some (.run "/usr/bin/xattr" #["-cr", "/s/staging/Leanmacs.app"]) &&
    steps[steps.size - 2]? ==
      some (.run "/usr/bin/codesign" #["--force", "--sign", "-", "/s/staging/Leanmacs.app"]) &&
    steps.back? == some .moveIntoPlace

/-- `Leanmacs.app`, the editor of a package set as a macOS app bundle, at
`<set>/.lake/build/Leanmacs.app`: `lake -d <set dir> build :editorApp`
(`mise run app`, on the default set; `docs/dev-practices/building.md`, "The
app bundle"). It is a facet of the set, as `editor` is, and nothing builds
it by default: the gate never does, and it is refused with the reason
anywhere but macOS on arm64 (`requireArm64Mac`).

`pkg` is the set, which holds the bundle, its trace, its staging directory
and its list of shipped files in its build directory. Everything else it
reads is the core's, this package's, found in the workspace by name: the
`stage-bundle` binary, this lakefile, the version file and the artwork.

It holds `Contents/MacOS/leanmacs`, the app's launcher (`launcher`), which is
the bundle's `CFBundleExecutable` and starts the editor by exec with
`CFProcessPath` pointing CoreFoundation at the bundle
(`docs/design/lean-runtime.md`, "The app's identity across an exec");
`Contents/MacOS/editor`, a copy of the set's `editor`, the shipped default;
under `Contents/Resources`, everything a user's package-set build needs,
so one builds from the app alone (`docs/design/lean-runtime.md`, "Build"):
the whole toolchain Lake runs on, which is the pinned one, the core and
each default package with their sources and build output, the set's
lakefile, the Rust archive and the link stubs, with the records
`editor.core`, `editor.oleans` and `editor.build`, laid out by
the `stage-bundle` binary (`stageBundle`) from what `editorShipped` lists;
`Contents/Info.plist`
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

The trace mixes the executable's, the shipped list's (`editorShipped`: a
hash of the place of each line, not of the path it is copied from, so a
clone of the checkout elsewhere has the same trace; the list's job carries
the trace of every module it lists),
the stager's (`stageBundle`), this lakefile's, the version file's and the artwork's traces with
the toolchain's, the platform's and the property list's, so the bundle is rebuilt, from nothing,
only when one of them changed, or when the bundle is gone. The property
list's trace is a hash of its text, which holds the build ID and the
commit, so a new commit rebuilds and re-signs the bundle. The lakefile is
in it because it is the recipe: without it, a change to how the bundle is
made would leave the old bundle standing. A rebuild assembles and signs the
bundle in `Leanmacs.app.staging` and only then renames it into place, since
Lake keeps the old trace when a build fails: a rebuild that fails or is
interrupted leaves the old bundle, never a half-built one the old trace
would take as up to date. -/
package_facet editorApp pkg : FilePath := do
  requireArm64Mac
  -- Before anything is linked: the binaries' minimum macOS must be no later
  -- than the bundle's.
  if let .error message :=
      deploymentTargetFits (← IO.getEnv deploymentTargetVar) appMinimumSystemVersion then
    error message
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  let exe ← fetch <| pkg.facet `editor
  let launcherJob ← launcher.fetch
  -- What the bundle ships of the set, built.
  let shippedJob ← fetch <| pkg.facet `editorShipped
  let stager ← stageBundle.fetch
  -- This file is the recipe, so a change to it rebuilds the bundle too.
  let recipe ← inputTextFile <| core.dir / "lakefile.lean"
  let versionJob ← inputTextFile <| core.dir / appVersionFile
  let artJob ← inputBinFile <| core.dir / appIconFile
  let inputs :=
    (((((((exe.zipWith Prod.mk shippedJob).zipWith Prod.mk stager).zipWith (fun paths _ => paths)
                  recipe).zipWith
              Prod.mk versionJob).zipWith
          Prod.mk artJob).zipWith
      Prod.mk launcherJob))
  inputs.mapM fun (((((exe, shipped), stager), versionFile), art), launcherFile) => do
      addLeanTrace
      addPlatformTrace
      -- The list names each file shipped; the content of each is in the
      -- trace of the module or target that built it, which the list's job
      -- carries. Only each line's place is hashed, not the file it is
      -- copied from, so a checkout in another directory has the same trace.
      let shippedText := "\n".intercalate shipped.toList ++ "\n"
      let places := shipped.map fun line => (line.splitOn "\t").getLastD line
      addTrace (.ofHash (pureHash places) "editorShipped")
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
          let list := pkg.buildDir / s!"{appName}.app.shipped"
          IO.FS.writeFile list shippedText
          -- The system's tools, by absolute path (`appSteps`): mise's PATH may
          -- hold others of the same name (a Python package installs an
          -- `xattr` with no `-r`). The iconset is in the staging directory but
          -- outside the bundle, so it is never sealed and goes with the
          -- staging directory.
          for step in appSteps stager launcherFile exe sysroot list staging art plist do
            match step with
            | .run cmd args =>
              proc (quiet := true) { cmd, args }
            | .write file text =>
              IO.FS.writeFile file text
            | .makeDirectory dir =>
              IO.FS.createDirAll dir
            | .moveIntoPlace =>
              -- Moved into place by renames: an interruption between them
              -- leaves the old bundle or none, and with none the next build
              -- rebuilds.
              if ← old.pathExists then
                IO.FS.removeDirAll old
              if ← bundle.pathExists then
                IO.FS.rename bundle old
              IO.FS.rename staged bundle
          IO.FS.removeDirAll staging
          if ← old.pathExists then
            IO.FS.removeDirAll old
      return bundle

/-- The model tests (`ModelTest.lean`, which imports its modules under
`ModelTest/`): `lake test` builds and runs this (`mise run lean-test`). It
is not a default target and links no glue and no Rust archive, so nothing it
needs reaches `rustlib`. `-L`: as in `linkArgs`, so it links under either
compiler. It starts at Lean's `main`. -/
@[test_driver] lean_exe «model-test» where
  root := `ModelTest
  plugins := lintPlugin
  moreLinkArgs := #["-L", leanSystemLibDir.toString]

/-- The model tests' modules (`ModelTest/**/*.lean`: the test modules under
`ModelTest/Editor/`, the support modules under `ModelTest/Support/` and
`ModelTest/Check.lean`), which the `model-test` executable's root
`ModelTest.lean` imports. Lake resolves an import only to a module of a
library, never to one of an executable's, so these need a library of their
own. It is not a default target: `lake test` builds it for the test driver.
`.submodules` takes every module under `ModelTest`, at any depth
(`ModelTest.Editor.Job.Contract`), and not `ModelTest` itself, so the
executable's root belongs to no library. -/
lean_lib ModelTests where
  globs := #[.submodules `ModelTest]
  plugins := lintPlugin

/-- The `ffi-test` executable's modules (`FfiTest/**/*.lean`: the test
modules under `FfiTest/Editor/`, the support modules under `FfiTest/Support/`
and `FfiTest/Check.lean`), which its root `FfiTest.lean` imports. Lake
resolves an import only to a module of a library, never to one of an
executable's, so these need a library of their own. It is not a default
target: the `ffi-test` executable, which is, imports it, so `lake build`
builds it and links its objects in. `.submodules` takes every module under
`FfiTest`, at any depth, and not `FfiTest` itself, so the executable's root
belongs to no library. -/
lean_lib FfiTests where
  globs := #[.submodules `FfiTest]
  plugins := lintPlugin

/-- The `contract-test` executable's modules (`ContractTest/**/*.lean`: the
test modules under `ContractTest/Editor/`, the support modules under
`ContractTest/Support/` and `ContractTest/Check.lean`), which its root
`ContractTest.lean` imports. Lake resolves an import only to a module of a
library, never to one of an executable's, so these need a library of their
own. It is not a default target: the `contract-test` executable, which is,
imports it, so `lake build` builds it and links its objects in.
`.submodules` takes every module under `ContractTest`, at any depth, and
not `ContractTest` itself, so the executable's root belongs to no library. -/
lean_lib ContractTests where
  globs := #[.submodules `ContractTest]
  plugins := lintPlugin

/-- The `config-test` executable's modules (`ConfigTest/**/*.lean`: the test
modules under `ConfigTest/Editor/`, the support modules under
`ConfigTest/Support/`, `ConfigTest/Check.lean` and the benchmark
`ConfigTest/Bench.lean`), which its root `ConfigTest.lean` imports. Lake
resolves an import only to a module of a library, never to one of an
executable's, so these need a library of their own. It is not a default
target: the `config-test` executable, which is, imports it, so `lake build`
builds it and links its objects in. `.submodules` takes every module under
`ConfigTest`, at any depth, and not `ConfigTest` itself, so the executable's
root belongs to no library. -/
lean_lib ConfigTests where
  globs := #[.submodules `ConfigTest]
  plugins := lintPlugin

/-- The contract checks of the text port and of the job port against their
real bindings (`ContractTest.lean`), linked like the editor with the glue and
the Rust archive. `mise run ffi-test` runs it. It interprets nothing, so it
does not export its symbols. -/
@[default_target] lean_exe «contract-test» where
  root := `ContractTest
  plugins := lintPlugin
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs.push coreSystemLibraries

/-- The tests of the build's linters (`LintTest.lean`, which imports its
modules under `LintTest/`): `lint-test` runs them (`mise run lean-test`).
They call the linters' functions, so they import `Lint`, and so they are
the one test executable that loads no plugin: importing the library
registers the linters as loading it would, and both would register them
twice. It links no glue and no Rust archive, as `model-test` does not, and
is not a default target, for the same reason. -/
lean_exe «lint-test» where
  root := `LintTest
  moreLinkArgs := #["-L", leanSystemLibDir.toString]

/-- The `lint-test` executable's modules (`LintTest/**/*.lean`), which its
root `LintTest.lean` imports, in a library of their own as the other test
executables' are. -/
lean_lib LintTests where globs := #[.submodules `LintTest]

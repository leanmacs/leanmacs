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
and a package `require`, and what the staged core of the user-side link is
called (`tools/user-link/core/lakefile.toml`).

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

/-- The editor's modules. Its root `Editor` is what user config is elaborated
on at runtime, and the build makes its `.olean` files for that. Its second
root, `Editor.Core`, is the core's (`Editor/Core.lean`,
`docs/design/packages.md`): it imports every module under `Editor/`,
directly or through another, so the build makes every core module, the
ones `Editor` does not import among them (the bindings, the real bindings
of the ports, the config session, the hosts, the test kit under
`Editor/Test/`). The list of the packages still in this Lake package is a
library of its own, below, and a feature that has moved out is another
Lake package's (`packages/`). -/
@[default_target] lean_lib Editor where roots := #[`Editor, `Editor.Core]

/-- The core's entry module (`EditorCore/EditorPackage.lean`): the list of
the packages the features still in this Lake package make. A Lake package
named `p` lists its packages in the module `<P>.EditorPackage`, `<P>` being
`p` in upper camel case, which is why this package is named `editor-core`:
`editor` would put the list at `Editor.EditorPackage`, under the namespace
the core imports check rules (`docs/design/packages.md`, "The package set
and its build"). The list names every package and so is no module of the
editor: it is a library of its own, outside `Editor/`, that the generated
root and the tests that need the list import. -/
lean_lib EditorCore where roots := #[`EditorCore.EditorPackage]

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
lean_lib FilesApi

/-- The test library of `files-api` (`FilesApiTest/`): its fake, the core's
kit's opener with the interface's hooks (`FilesApiTest.Fake`), and its
contract check (`FilesApiTest.Contract`). -/
lean_lib FilesApiTest where globs := #[.submodules `FilesApiTest]

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

/-- An extension point and a compiled package that reads it
(`ExtensionFixture.lean`), for the checks that config elaborated at runtime
registers at a compiled package's extension point. `config-test` imports
it, so it is linked into that executable, and the same executable imports
its `.olean` again at runtime as part of the base config is elaborated
on. -/
lean_lib ExtensionFixture

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

/-- A Rust crate of a package of a set (`setRustCrates`): the Lake package
that declares it, the crate's name, read from its manifest, and the
manifest's absolute path. -/
structure RustCrate where
  /-- The name of the Lake package that declares the crate. -/
  owner : String
  /-- The crate's name: its manifest's `package.name`. -/
  name : String
  /-- The crate's manifest, absolute. -/
  manifest : FilePath

/-- The name of the crate whose manifest is `manifest`, read with Lake's own
TOML reader: the manifest's `package.name`. -/
def crateName (manifest : FilePath) : IO String := do
  let input ← IO.FS.readFile manifest
  let refused := IO.userError s!"{manifest} holds no `package.name` Lake can read"
  match ← (Lake.Toml.loadToml (Lean.Parser.mkInputContext input manifest.toString)).toBaseIO with
  | .ok table =>
    match table.find? `package with
    | some (.table _ fields) =>
      match fields.find? `name with
      | some (.string _ name) =>
        return name
      | _ =>
        throw refused
    | _ =>
      throw refused
  | .error _ =>
    throw refused

/-- What the Rust archive of a set is keyed by: its package crates' Lake
packages, in the order they register, joined with `-`; `core` for a set
with none. Sets with the same package crates share one generated crate, one
Cargo build and one archive. -/
def rustKey (crates : Array RustCrate) : String :=
  if crates.isEmpty then "core" else "-".intercalate (crates.map (·.owner)).toList

/-- The name of the crate generated for the key `key`: `editor-rust`, or
`editor-rust-<key>` for a set with package crates. Its archive is
`lib<name, with `_` for `-`>.a`. -/
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

/-- The manifest of the crate `name`, generated for the package crates
`crates`: a `staticlib` whose dependencies are `editor-ffi`, at `ffi`, and
each package crate, by absolute path under its own name. It is a workspace
of its own, so it builds outside the repository's. -/
def rustManifest (name : String) (ffi : FilePath) (crates : Array RustCrate) : String :=
  let dependencies :=
    crates.foldl
      (fun text crate =>
        text ++
          s!"{tomlString crate.name} = \{ path = {tomlString (crate.manifest.parent.getD "." |>.toString)} }\n")
      ""
  s!"# Generated by the package-set build (`editorRustCrate` in lean/lakefile.lean)
# from the package crates of a set. Do not edit it: the build writes it again.
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
{dependencies}"

/-- The library of a generated crate: it re-exports `editor-ffi` and each
package crate, so every one of them is linked into its archive. -/
def rustLibrary (crates : Array RustCrate) : String :=
  let uses :=
    crates.foldl (fun text crate => text ++ s!"pub use {crate.name.replace "-" "_"};\n") ""
  s!"//! The Rust archive of a package set, generated by the package-set build
//! (`editorRustCrate` in lean/lakefile.lean): `editor-ffi` and the crate of
//! each package of the set that holds Rust. Do not edit it: the build writes
//! it again.

pub use editor_ffi;
{uses}"

/-- The cargo-deny config of the crate `name`, generated for the package
crates `crates` (`tools/rust-bans-check.sh`): in its graph the generated
crate is the one crate allowed to depend on `editor-ffi` or on a package
crate, so a package crate that depends on `editor-ffi` or on another
package's crate is banned; and `editor-release-std`, the release tooling's
adapters, is banned outright. A package crate may depend on
`editor-service`, which has no entry. The root `deny.toml` cannot say this:
nothing in the root graph depends on `editor-ffi` or on a package crate,
and cargo-deny bans a crate with no parents under `wrappers = []`. -/
def rustDenyConfig (name : String) (crates : Array RustCrate) : String :=
  let wrapped (crate : String) : String :=
    s!"  \{ crate = {tomlString crate}, wrappers = [{tomlString name}], reason = \"a package's crate depends on editor-service and on nothing else of the editor's: only the generated crate links editor-ffi and each package's crate\" },\n"
  let entries := crates.foldl (fun text crate => text ++ wrapped crate.name) (wrapped "editor-ffi")
  s!"# Generated by the package-set build (`editorRustCrate` in lean/lakefile.lean)
# from the package crates of a set, for tools/rust-bans-check.sh. Do not edit
# it: the build writes it again.
[bans]
multiple-versions = \"allow\"
deny = [
{entries}  \{ crate = \"editor-release-std\", reason = \"the release tooling's adapters are no part of the editor\" },
]
"

/-- Writes the crate generated for the package crates `crates` in the
repository `root` (`rustDir`), each file only when its text would change,
and gives its directory: `Cargo.toml` (`rustManifest`), `lib.rs`
(`rustLibrary`), the bans `tools/rust-bans-check.sh` holds it to
(`deny.toml`, `rustDenyConfig`), and a `Cargo.lock` seeded from the root's whenever the
root's changes, so the crate builds against the versions the root lock
holds. -/
def writeRustCrate (root : FilePath) (crates : Array RustCrate) : IO FilePath := do
  let key := rustKey crates
  let dir := rustDir root key
  writeIfChanged (dir / "Cargo.toml")
      (rustManifest (rustCrateName key) (← IO.FS.realPath (root / "crates" / "editor-ffi")) crates)
  writeIfChanged (dir / "lib.rs") (rustLibrary crates)
  writeIfChanged (dir / "deny.toml") (rustDenyConfig (rustCrateName key) crates)
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

/-- Builds the archive of the crate generated for `crates` in the repository
`root` (`writeRustCrate`) and gives its path:
`target/release/lib<crate>.a`, in the root's target directory, which every
generated crate shares, so a dependency is built once whatever crate needs
it. Beside the crate it leaves the system libraries the archive needs
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
def buildRust (root : FilePath) (crates : Array RustCrate) : FetchM (Job FilePath) :=
  Job.async do
    requireSupportedPlatform
    let dir ← writeRustCrate root crates
    let name := rustCrateName (rustKey crates)
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

/-- The Rust archive of the core alone: the crate generated for a set with
no package crate, key `core` (`buildRust`), which holds `editor-ffi`. The
core's own executables link it (`ffi-test`, `config-test`,
`contract-test`), and so does every set whose packages hold no crate
(`editorRust`), so they all share one Cargo build and one archive. -/
target rustlib pkg : FilePath :=
  buildRust (pkg.dir / "..") #[]

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

/-- The C glue between `@[extern]` declarations and the Rust library
(`ffi/glue.c`), compiled against the toolchain's own `lean.h`. Nothing lints C
for us, so every warning is an error. -/
target glue.o pkg : FilePath := do
  requireSupportedPlatform
  let oFile := pkg.buildDir / "ffi" / "glue.o"
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  buildLeanO oFile srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

/-- The directory of the static libraries Lean's runtime needs (libgmp, libuv
and the rest), inside the Lean toolchain Lake itself is using, as this
lakefile is elaborated: for the core's own `lean_exe`s, whose `moreLinkArgs`
are fixed then. It asks Lake as Lake finds its own toolchain
(`Lake.findInstall?`), which takes the `lean` beside the running `lake`
first, so it never reads the `PATH`: an app bundle's `lake`, run with no
`lean` on the `PATH`, or with a user's other Lean there, elaborates this
lakefile against its own toolchain (`docs/design/lean-runtime.md`, "Build").
The editor's own link asks the workspace's toolchain as it runs instead
(`editorLinkArgs`). -/
def leanSystemLibDir : FilePath :=
  run_io
    do
      let (_, some lean, _) ←
        Lake.findInstall? | throw <| IO.userError "cannot find the Lean toolchain to link against"
      return lean.systemLibDir

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
So a package's crate that needs a system library links with no edit
here. -/
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

/-- The packages of the set `set`, in the order their entry modules
register: `set` and every package it requires, directly or through
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
partial def setPackages (ws : Workspace) (set : Package) : Array Package :=
  (visit set (#[], #[])).2
where
  /-- Visits `pkg` after its dependencies: `state` is the names of the
  packages entered so far and the packages in order so far. -/
  visit (pkg : Package) (state : Array Name × Array Package) : Array Name × Array Package :=
    if state.1.contains pkg.keyName then state
    else
      let state :=
        pkg.depConfigs.foldl
          (fun state dep =>
            match ws.findPackageByName? dep.name with
            | some dep => visit dep state
            | none => state)
          (state.1.push pkg.keyName, state.2)
      (state.1, state.2.push pkg)

/-- The repository the core is in: the directory above the core's. -/
def repositoryRoot : FetchM FilePath := do
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  return core.dir / ".."

/-- The Rust crates of the set `set`, in the order their packages register
(`setPackages`): a package declares its crate with a target named
`editorRustCrate` whose value is the path of the crate's manifest. The
target's value is read through its own declaration (its fetch function and
its query format), so this names no type of the package's, and no list is
kept by hand. A crate whose manifest is outside the repository is refused
with its reason: its dependencies are not in the core's lock, and
`editor-service` has no published name for it to depend on
(`docs/design/packages.md`, "Who can build it"). -/
def setRustCrates (set : Package) : FetchM (Array RustCrate) := do
  let ws ← getWorkspace
  let mut crates : Array RustCrate := #[]
  for dep in setPackages ws set do
    let some decl := dep.findTargetDecl? `editorRustCrate | continue
    let owner := dep.baseName.toString (escape := false)
    let some config := decl.targetConfig?
      | error s!"the package {owner} declares `editorRustCrate`, but not as a target"
    let data ← (← config.fetchFn ⟨dep, rfl⟩).await
    let manifest ← IO.FS.realPath (config.format .text data)
    let name ← crateName manifest
    let root := (← IO.FS.realPath (← repositoryRoot)).toString
    unless manifest.toString.startsWith (root ++ "/") do
      error
          s!"{owner}'s Rust crate {name} is outside the editor's Cargo workspace ({root}): building a third party's Rust is not supported yet; see docs/design/packages.md, 'Who can build it'"
    crates := crates.push { owner, name, manifest }
  return crates

/-- The line `editorRustCrates` prints for `crate`: its Lake package, its
name and its manifest, separated by tabs. -/
def RustCrate.line (crate : RustCrate) : String :=
  s!"{crate.owner}\t{crate.name}\t{crate.manifest}"

/-- The Rust crates of a package set, one a line
(`lake -d <set dir> query :editorRustCrates`; `setRustCrates`): the Lake
package, the crate's name and its manifest, separated by tabs, in the order
the packages register. Empty for a set with no Rust. It builds nothing. -/
package_facet editorRustCrates pkg : Array String := do
  return Job.pure ((← setRustCrates pkg).map RustCrate.line)

/-- The crate generated from a set's Rust crates, written and not built
(`lake -d <set dir> query :editorRustCrate`; `writeRustCrate`): it prints
its directory, `target/editor-rust/<key>`. `tools/rust-bans-check.sh` runs
cargo-deny over it. -/
package_facet editorRustCrate pkg : FilePath := do
  return Job.pure (← writeRustCrate (← repositoryRoot) (← setRustCrates pkg))

/-- Where the Rust archive of a set's editor comes from
(`docs/design/packages.md`, "Who can build it"). -/
inductive RustSource where
  /-- Built by Cargo: the core's archive (`rustlib`) or the crate generated
  from the set's crates (`buildRust`). -/
  | cargo
  /-- The core's archive as it is already built, read and never built: no
  Cargo runs. -/
  | prebuilt
  deriving DecidableEq, Repr

/-- Where the archive of a set comes from, given its crates and whether the
set is in the repository: a set outside it that holds no crate, a user's,
reuses the core's archive as it is built, so a user's set with no Rust
links with no Cargo (decided 2026-11-20: the editor never ships Cargo);
every other set is built by Cargo, the checkout's own sets among them, so
a change to the core's Rust is built. -/
def rustSource (crates : Array RustCrate) (inRepository : Bool) : RustSource :=
  if crates.isEmpty && !inRepository then .prebuilt else .cargo

#guard rustSource #[] false == .prebuilt

#guard rustSource #[] true == .cargo

#guard
  rustSource #[{ owner := "echo", name := "echo-service", manifest := "/r/echo/Cargo.toml" }]
      false ==
    .cargo

/-- Whether the directory of `pkg` is inside the repository `root`. -/
def isInRepository (root : FilePath) (pkg : Package) : IO Bool := do
  let root := (← IO.FS.realPath root).toString
  let dir := (← IO.FS.realPath pkg.dir).toString
  return dir == root || dir.startsWith (root ++ "/")

/-- The core's archive in the repository `root` and the file of the system
libraries it needs, as Cargo builds them for the core (`rustlib`):
`target/release/libeditor_rust.a` and
`target/editor-rust/core/native-static-libs`. -/
def prebuiltRustFiles (root : FilePath) : FilePath × FilePath :=
  (root / "target" / "release" / s!"lib{(rustCrateName "core").replace "-" "_"}.a",
    systemLibrariesFile (rustDir root "core"))

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
          s!"the core's Rust archive is not built ({archive} and {libraries}): a set with no Rust reuses it and runs no Cargo"
    setTrace (← computeTrace archive)
    addPureTrace (← IO.FS.readFile libraries) "native-static-libs"
    return archive

/-- The core's own archive for the set `pkg`: `rustlib`, built by Cargo,
for a set in the repository; the prebuilt one (`prebuiltRust`) for one
outside it, a user's. -/
def coreArchive (pkg : Package) : FetchM (Job FilePath) := do
  let root ← repositoryRoot
  if ← isInRepository root pkg then
    rustlib.fetch
  else
    prebuiltRust root

/-- Where the archive of the set `pkg` comes from (`lake -d <set dir> query
:editorRustSource`; `rustSource`): `cargo` or `prebuilt`, one line. It
builds nothing. -/
package_facet editorRustSource pkg : String := do
  let source := rustSource (← setRustCrates pkg) (← isInRepository (← repositoryRoot) pkg)
  return Job.pure (if source == .prebuilt then "prebuilt" else "cargo")

/-- The one Rust archive of a set's editor (`lake -d <set dir> build
:editorRust`): the crate generated from the set's Rust crates, built
(`buildRust`), whose dependencies are `editor-ffi` and each package crate.
A set with no package crate has the core's: built by Cargo (`rustlib`) for
a set in the repository, and reused as it is built, with no Cargo, for a
user's (`rustSource`, `prebuiltRust`). The system libraries the archive
needs are beside the generated crate (`systemLibrariesFile`). -/
package_facet editorRust pkg : FilePath := do
  let crates ← setRustCrates pkg
  let root ← repositoryRoot
  match rustSource crates (← isInRepository root pkg) with
  | .prebuilt =>
    prebuiltRust root
  | .cargo =>
    if crates.isEmpty then
      rustlib.fetch
    else
      buildRust root crates

/-- The link arguments, one a token, in the file of system libraries
`file` (`systemLibrariesFile`). -/
def systemLibraryArgs (file : FilePath) : IO (Array String) := do
  let text ← IO.FS.readFile file
  return ((text.split Char.isWhitespace).filter (!·.isEmpty)).toArray.map (·.toString)

/-- The directory of the link stubs in the repository `root`:
`<root>/link-stubs`, which `tools/stage-bundle.sh` writes into an app
bundle's `Contents/Resources/lean` from the shipped editor
(`tools/link-stubs.sh`). -/
def linkStubsDir (root : FilePath) : FilePath :=
  root / "link-stubs"

/-- The link arguments that name the system's libraries from the link stubs
in `stubs`, whose entries are `names` and whose `platform-version` file
holds `version`: the two search paths, then a framework for each
`<name>.framework` and a library for each `lib<name>.tbd`, in order of
their names, then the platform version, `<minos> <sdk>`, so the
executable records the SDK version the shipped editor's own link recorded.
These are the arguments `tools/user-link/package/lakefile.lean` proved in
phase 1 (`docs/design/lean-runtime.md`, "A link on the user's machine,
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

/-- Links an executable at `file`, rooted at the module `root`, as the
editor is linked: `root`'s object and those of every module it imports,
with their symbols exported, so interpreted config can find compiled
definitions and `@[extern]` symbols (`-rdynamic`, what `supportInterpreter`
gives a `lean_exe`), the glue of every package library it imports among
them (a library's `moreLinkObjs`); then the core's glue and the one Rust
archive of the set `set` (`editorRust`); then `linkArgs`, with the
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
directory. -/
def linkAsEditor (set : Package) (root : Module) (file : FilePath) : FetchM (Job FilePath) := do
  let infoJob ← root.linkInfoExport.fetch
  let glueJob ← glue.o.fetch
  let rustJob ← (set.facet `editorRust).fetch
  let libraries := systemLibrariesFile (rustDir (← repositoryRoot) (rustKey (← setRustCrates set)))
  let entry ← editorLinkArgs
  let fromStubs := linksFromStubs Platform.isOSX (← getLeanInstall).customCc
  let stubs := linkStubsDir (← repositoryRoot)
  ((infoJob.zipWith Prod.mk glueJob).zipWith Prod.mk rustJob).mapM fun ((info, glue), rust) => do
      let system ←
        if fromStubs then
          unless ← stubs.isDir do
            error
                s!"linking with the toolchain's own clang needs link stubs at {stubs} (tools/link-stubs.sh), and there are none: set LEAN_CC to a compiler that links against the macOS SDK, or build from an app bundle, which ships them"
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

/-- The text of a set's root module, for the entry modules `entries` in the
order they register and the config base `base` (`setBase`). It imports the
core's base, `Editor`, for the link alone (`Editor/Main.lean`, "This module
names no package, and not the config base"), then the executable's entry,
then each entry module; and its `main` is one call of `Editor.Main.run`
with the entry modules' `packages` appended in that order, the base as an
array of names, and what the build says of the editor for the files it
generates in a config directory (`Editor/Config/LakePackage.lean`,
`Origin`): `setName`, the Lake name of the set, and `pin`, the text of the
core's `lean-toolchain`. Every module of the base is among its imports, so
each is linked into the executable, which the elaborator requires of a
module it imports at runtime.

`schemes` are the entry modules that supply an input scheme (`SetEntry.scheme`),
in the order they register: `run` is handed the `scheme` of each, as an
array, and runs the last (`Editor/Main.lean`, "The input scheme"). With
none the array is empty, and the editor refuses to start. -/
def rootSource (entries schemes base : Array Name) (setName pin : String) : String :=
  let imports := entries.foldl (fun text name => text ++ s!"import {name}\n") ""
  let lists :=
    if entries.isEmpty then "#[]"
    else " ++ ".intercalate (entries.map fun name => s!"{name}.packages").toList
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

/-- The name of the root module the package-set build generates. No library
declares it. -/
def setRootName : Name :=
  `EditorSetRoot

/-- The keyword a Lake package declares in its lakefile when it supplies
the editor's input scheme (`keywords = ["editor-input-scheme"]`, Lake's own
package key, as `editor-interface` is, `layerOf`): its entry module then
declares `scheme : Editor.SchemePackage` beside `packages`, in the
namespace of its own name (`docs/design/packages.md`, "Input schemes").
Lake is asked for the keyword, so the build reads no source: a package
that declares it and no `scheme` fails the generated root's build, which
names `<P>.EditorPackage.scheme`, as a missing `packages` does. -/
def schemeKeyword : String :=
  "editor-input-scheme"

/-- An entry module of a set. -/
structure SetEntry where
  /-- Whether its Lake package is this one, the core. -/
  core : Bool
  /-- The module's name. -/
  module : Name
  /-- Whether its Lake package supplies an input scheme (`schemeKeyword`). -/
  scheme : Bool

/-- The entry modules of the set `pkg`, in the order they register
(`setPackages`, `entryModule?`), each with whether its Lake package is this
one, the core, and whether it supplies an input scheme (`schemeKeyword`).
A package that declares the scheme keyword and has no entry module is an
error that names it: there is nowhere for its scheme to be declared. -/
def setEntries (pkg : Package) : FetchM (Array SetEntry) := do
  let ws ← getWorkspace
  let mut entries : Array SetEntry := #[]
  for dep in setPackages ws pkg do
    let scheme := dep.keywords.contains schemeKeyword
    match ← entryModule? dep with
    | some mod =>
      entries := entries.push { core := dep.keyName == __name__, module := mod.name, scheme }
    | none =>
      if scheme then
        error
            s!"the package {dep.baseName.toString (escape := false)} declares the keyword {schemeKeyword} and has no entry module {entryModuleName dep}: a package that supplies the input scheme declares `scheme` there"
  return entries

/-- The config base of a set, from its entry modules (`setEntries`): the
modules its editor elaborates config on. `Editor`, the core's base
(`Editor.lean`), then the entry module of each package of the set outside
the core, in the order they register, so that config can name what a
package of the set declares: an entry module imports its package's modules.
The core's own entry module is not in it: the core's base is `Editor`, and
what config sees of the core does not change with the set
(`docs/design/packages.md`, "The package set and its build"). -/
def setBase (entries : Array SetEntry) : Array Name :=
  #[`Editor] ++ (entries.filter (!·.core)).map (·.module)

/-- The root module of the set `pkg`, written from the entry modules of the
set's packages (`setEntries`, `setBase`, `rootSource`), the set's Lake name
and the text of the core's `lean-toolchain`, to
`<set>/.lake/build/root/EditorSetRoot.lean`, and only when its text would
change, so a build with nothing to do writes nothing.

No library of the set declares the module: it is a module of a library
value made here, in the set's package, whose source directory is that
directory, so its `.olean` and its object are in the set's build directory.
That library takes this package's Lean options, so a warning in the root
fails the build. Lake builds an executable's root the same way
(`LeanExe.root`). -/
def setRoot (pkg : Package) : FetchM Module := do
  let entries ← setEntries pkg
  let lib : LeanLib :=
    ⟨pkg, `EditorSet,
      { srcDir := pkg.config.buildDir / "root", roots := #[], leanOptions := coreLeanOptions }⟩
  let root : Module := { lib, name := setRootName }
  let ws ← getWorkspace
  let some core := ws.findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  -- The pin is the core's: every copy of it in the repository is held to
  -- that one file (`tools/toolchain-check.sh`).
  let pin ← IO.FS.readFile (core.dir / "lean-toolchain")
  writeIfChanged root.leanFile
      (rootSource (entries.map (·.module)) ((entries.filter (·.scheme)).map (·.module))
        (setBase entries) (pkg.baseName.toString (escape := false)) pin)
  return root

/-- The `.olean` directories of the set `pkg`: the core's first, then that
of each other package of the set that holds a Lean library, in the order
they register (`setPackages`). They are what the set's editor searches for
the modules of its config base (`setBase`). -/
def moduleDirectories (pkg : Package) : FetchM (Array FilePath) := do
  let ws ← getWorkspace
  let some core := ws.findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  let others :=
    (setPackages ws pkg).filter fun dep => dep.keyName != __name__ && !dep.leanLibs.isEmpty
  return #[core.leanLibDir] ++ others.map (·.leanLibDir)

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

/-- The record of where a package set is, written beside the editor the
set's build links, at `<executable>.set`: the set's directory, absolute,
on one line. An editor run directly, outside a bundle, reads it
(`Editor/ModuleLookup.lean`, "The set") to name the set in the lakefile it
generates for a config directory, so that Lean's language server, started
there, finds the modules config imports. It is written only when its text
would change. -/
def writeSetRecord (pkg : Package) (executable : FilePath) : FetchM Unit := do
  writeIfChanged (executable.toString ++ ".set") s!"{← IO.FS.realPath pkg.dir}\n"

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
  let directory ←
    if core.dir.isAbsolute then
      pure core.dir
    else
      (· / core.dir) <$> IO.currentDir
  writeIfChanged (executable.toString ++ ".coredir") s!"{directory}\n"

/-- The variables a rebuild of a set must run with as the link did, and
which the record `<executable>.build` holds (`buildRecordText`): the C
compiler Lake compiles and links with (`LEAN_CC`; `mise run lean` sets
`/usr/bin/cc`) and the lowest macOS the link targets
(`MACOSX_DEPLOYMENT_TARGET`). A user's set rebuilt without them could make
the core's shared outputs out of date, or fail to link the system
frameworks (`docs/design/packages.md`, "User package sets"). -/
def buildVariables : Array String :=
  #["LEAN_CC", "MACOSX_DEPLOYMENT_TARGET"]

/-- The text of the record `<executable>.build`: one line `NAME=value` for
each of `buildVariables` that is set, in that order, as the environment of
this build holds it; nothing for one that is unset. -/
def buildRecordText : IO String :=
  buildVariables.foldlM
    (fun text name => do
      match ← IO.getEnv name with
      | some value =>
        return text ++ s!"{name}={value}\n"
      | none =>
        return text)
    ""

/-- The core's identity, as a job: a hash, in hex, of what an editor links
of the core, so two editors over one core have the same identity whatever
their sets hold, and any change to the core gives a new one
(`docs/design/packages.md`, "User package sets"). It mixes the traces of
the objects of every module of the core's two libraries (`Editor` and
`EditorCore`; the whole libraries, so a package that imports a core module
the default set does not link still has its core's identity), the core's
glue (`glue.o`), the core's Rust archive (`coreArchive`: `rustlib`, or
the same archive reused for a user's set) and the version of the Lean
toolchain Lake runs on. The objects' traces are Lake's input hashes,
which change when a module's source, its imports or the compiler change. -/
def coreIdentity (pkg : Package) : FetchM (Job String) := do
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  let mut libraries : Array (Job (Array Module)) := #[]
  for name in [`Editor, `EditorCore] do
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
      let parts :=
        hashes ++ #[glueJob.getTrace.hash, rustJob.getTrace.hash, pureHash Lean.versionString]
      return (parts.foldl Hash.mix Hash.nil).hex

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
(`writeCoreDirRecord`), which an editor run directly reads,
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
  let identity ←
    (← coreIdentity pkg).mapM fun identity =>
        writeIfChanged (executable.toString ++ ".core") s!"{identity}\n"
  return (← linkAsEditor pkg (← setRoot pkg) executable).add identity

/-- The variable `editorInstall` takes the directory it installs into from. -/
def installDirVar : String :=
  "EDITOR_INSTALL_DIR"

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
  (`editorRootTransImports`), from the directory each was built in;
- `editor.oleans`, the one relative line `lib/lean`
  (`Editor/ModuleLookup.lean`, "The record"), so `<dir>` can be renamed
  into place afterwards.

The modules are copied, not referenced, so a later build that rewrites a
package's `.olean` files leaves this editor's modules matching its linked
code. The toolchain's own modules stay in the toolchain. It prints the
directory it filled. -/
package_facet editorInstall pkg : FilePath := do
  let exeJob ← fetch <| pkg.facet `editor
  let root ← setRoot pkg
  let importsJob ← root.transImports.fetch
  (exeJob.zipWith Prod.mk importsJob).mapM fun (exe, imports) => do
      let refused :=
        s!"{installDirVar} must name the directory to install the editor into, which must not exist yet"
      let dir : FilePath ←
        match ← IO.getEnv installDirVar with
        | some given =>
          pure given
        | none =>
          error refused
      if ← dir.pathExists then
        error s!"{dir} already exists: the editor is installed only into a directory that does not"
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
      IO.FS.writeFile (dir / "editor.oleans") "lib/lean\n"
      if Platform.isOSX then
        proc (quiet := true)
            { cmd := "/usr/bin/codesign",
              args := #["--force", "--sign", "-", (dir / "editor").toString] }
      return dir

/-- The root module of a package set, written and not built:
`lake -d <set dir> query :editorRoot` writes
`<set>/.lake/build/root/EditorSetRoot.lean` when its text would change
(`setRoot`) and prints its path. It links nothing and builds no module.

It is the generator of the package-set build on its own, for a link that
is not Lake's here: the user-side link check stages the root of its
fixture set with prebuilt pieces of the core and links them with the Lean
toolchain's own linker (`tools/user-link-check.sh`), so that root is
generated as the editor's is and written by no one. -/
package_facet editorRoot pkg : FilePath := do
  let root ← setRoot pkg
  return Job.pure root.leanFile

/-- The direct imports of a set's root module, one module a line
(`lake -d <set dir> query :editorRootImports`): the config base, the
executable's entry and the set's entry modules, as the workspace resolves
them. No library declares the root, so `lake query +<module>:imports` does
not find it; the host imports check asks this instead
(`tools/host-imports-check.sh`). It writes the root when its text would
change and builds nothing. -/
package_facet editorRootImports pkg : Array String := do
  let root ← setRoot pkg
  (← root.imports.fetch).mapM fun modules => return modules.map (·.name.toString)

/-- The transitive imports of a set's root module, one module a line
(`lake -d <set dir> query :editorRootTransImports`): every module of the
workspace linked into the set's editor, but the root. The core imports
check asks this for the default set (`tools/core-imports-check.sh`). It
writes the root when its text would change and builds nothing. -/
package_facet editorRootTransImports pkg : Array String := do
  let root ← setRoot pkg
  (← root.transImports.fetch).mapM fun modules => return modules.map (·.name.toString)

/-- The config base of a package set, one module a line
(`lake -d <set dir> query :editorBase`; `setBase`): `Editor`, then the
entry module of each package of the set outside the core. It is what the
generated root hands `Editor.Main.run`, and what `mise run module-bench`
takes the closure of. It reads no source and builds nothing. -/
package_facet editorBase pkg : Array String := do
  return Job.pure ((setBase (← setEntries pkg)).map (·.toString))

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
test library (`lean_lib FilesApi`, above): the config base imports them
through the features still in the core, so the bundle ships them as it ships
`Editor`. One moves out of this list when it moves to `packages/`, as
`VcApi` and `ProjectApi` did in phase 6. -/
def stagedInterfaceLibraries : List Lean.Name :=
  [`FilesApi, `FilesApiTest]

/-- Whether a library of `pkg` ships its modules built in the bundle
(`editorShipped`): of the core, `Editor` and `EditorCore`, the libraries
`coreIdentity` reads, and the interface libraries staged in it
(`stagedInterfaceLibraries`), whose changes reach the identity through the
traces of the core's modules that import them; of another package, each
library but its tests, `<P>Test`. -/
def shipsLibrary (pkg : Package) (lib : LeanLib) : Bool :=
  if pkg.keyName == __name__ then
    lib.name == `Editor || lib.name == `EditorCore || stagedInterfaceLibraries.contains lib.name
  else
    match toUpperCamelCase pkg.baseName with
    | .str namespace_ base => lib.name != .str namespace_ (base ++ "Test")
    | _ => true

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
      let entries := (← dir.readDir).filter (·.fileName.startsWith stem)
      files := files ++ (entries.map (·.path)).qsort (·.toString < ·.toString)
  return files

/-- What an app bundle ships of the set `pkg`, built (`lake -d <set dir>
query :editorShipped`; `docs/design/lean-runtime.md`, "Build"), so a
user's package-set build from the bundle compiles nothing of it: one line
`file<TAB><source><TAB><place>` for each file, its place relative to the
bundle's `Contents/Resources/lean`, and one line `oleans<TAB><place>` for
each `.olean` directory of the set (`moduleDirectories`), in order, its
place relative to `Contents/Resources`, which the bundle's record
`editor.oleans` holds (`Editor/ModuleLookup.lean`, "The bundle's record").

The core goes to `lean`, the set to `set` and each package under the set's
directory to the same place under `set` (`shippedPlace`), so the set's and
the packages' lakefiles name the bundle's core unchanged; a package
elsewhere is refused. For each package of the set (`setPackages`): its
lakefile, `lake-manifest.json` and `lean-toolchain`; and for every module
of each library that ships (`shipsLibrary`, `libraryModules`: of the core,
`Editor` and `EditorCore`; of the others, each library but its tests), its
source and every file Lake wrote for it (`builtFiles`). Of the core, also
its glue, `ffi/glue.c`, with `glue.o` built and its trace and hash. Then
the core's Rust archive and its system libraries
(`prebuiltRustFiles`), at `target/` under `lean`, which is where a user's
set outside the bundle's `lean` reads them (`prebuiltRust`,
`repositoryRoot`).

It fetches each listed module's `oExport`, and so its `.olean`, `.ilean`
and C file, and `glue.o`, so every file it lists is built. It builds no
Rust: the archive must be built already. `tools/stage-bundle.sh` copies
what it lists and decides nothing; which modules exist is Lake's
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
  let directories ← moduleDirectories pkg
  let glueJob ← glue.o.fetch
  let root ← repositoryRoot
  let modulesJob := (Job.collectArray libraries).map (·.flatten)
  let builtJob ←
    modulesJob.bindM fun modules => do
        let jobs ← modules.mapM (·.oExport.fetch)
        return (Job.collectArray jobs).map fun _ => modules
  (builtJob.zipWith Prod.mk glueJob).mapM fun (modules, _) => do
      let placeOf (dep : Package) : Option String :=
        (placed.find? (·.1.keyName == dep.keyName)).map (·.2)
      let mut lines : Array String := #[]
      let line (source : FilePath) (place : String) : String := s!"file\t{source}\t{place}"
      for (dep, place) in placed do
        for file in [dep.configFile, dep.dir / "lake-manifest.json", dep.dir / "lean-toolchain"] do
          if ← file.pathExists then
            let some relative := relativeUnder dep.dir file
              | error s!"{file} is not under its package's directory {dep.dir}"
            lines := lines.push (line file s!"{place}/{relative}")
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
      let (archive, libraries) := prebuiltRustFiles root
      for file in [archive, libraries] do
        let some relative := relativeUnder root file
          | error s!"{file} is not under the repository {root}"
        lines := lines.push (line file relative)
      for directory in directories do
        let some dep := placed.find? fun (dep, _) => directory == dep.leanLibDir
          | error s!"the .olean directory {directory} is of no package of the set"
        let some relative := relativeUnder dep.1.dir directory
          | error s!"{directory} is not under its package's directory {dep.1.dir}"
        lines := lines.push s!"oleans\tlean/{dep.2}/{relative}"
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

/-- The direct imports of the core's modules by the packages of a set, for
the package imports check (`tools/package-imports-check.sh`;
`lake -d <set dir> query :editorPackageImports`;
`docs/design/packages.md`, "What a package may import"). For each package
a gate step runs over (`editorPackages`), each module of its libraries and
each module it imports directly that is a module of this Lake package, the
core's, one line, its fields separated by tabs: the package's name, the
importing module, that module's kind and the module imported. The kind is
`linked` for the root of the package's linked test (`linkedTestModule?`),
`linked-test` for a module under that root (`<P>Test.Linked.…`), which the
linked test imports and so is linked with the Rust library, `test` for any
other module under `<P>Test`, and `library` for the rest.
It reads each module's header, as Lake does to resolve imports, and builds
nothing. -/
package_facet editorPackageImports pkg : Array String := do
  let ws ← getWorkspace
  let mut jobs : Array (Job (Array String)) := #[]
  for dep in setPackages ws pkg do
    if dep.keyName == __name__ || !dep.remoteUrl.isEmpty || dep.leanLibs.isEmpty then
      continue
    let name := dep.baseName.toString (escape := false)
    let testRoot : Name :=
      match toUpperCamelCase dep.baseName with
      | .str namespace_ base => .str namespace_ (base ++ "Test")
      | other => other
    let linkedRoot : Name := .str testRoot "Linked"
    let kindOf (mod : Module) : String :=
      if mod.name == linkedRoot then "linked"
      else if linkedRoot.isPrefixOf mod.name then "linked-test"
      else if testRoot.isPrefixOf mod.name then "test"
      else "library"
    for lib in dep.leanLibs do
      let job ←
        (← lib.modules.fetch).bindM fun mods => do
          let lines ←
            mods.mapM fun mod => do
              (← mod.imports.fetch).mapM fun imports =>
                return imports.filterMap fun imported =>
                    if imported.pkg.keyName == __name__ then
                      some s!"{name}\t{mod.name}\t{kindOf mod}\t{imported.name}"
                    else none
          return (Job.collectArray lines).map (·.flatten)
      jobs := jobs.push job
  return (Job.collectArray jobs).map (·.flatten)

/-- The layer of the Lake package `dep` in the three-layer import rule
(`docs/design/extension-points.md`, "Three layers"): `core` for this
package, `interface` for a package whose lakefile declares the keyword
`editor-interface` (`keywords = ["editor-interface"]`, Lake's own package
key), and `implementation` for every other package, so a misspelt keyword
makes a package more refused, never less. -/
def layerOf (dep : Package) : String :=
  if dep.keyName == __name__ then "core"
  else if dep.keywords.contains "editor-interface" then "interface" else "implementation"

/-- The direct imports of the modules of the core and of every package of a
set, for the layer imports check (`tools/layer-imports-check.sh`;
`lake -d <set dir> query :editorLayerImports`;
`docs/dev-practices/the-gate.md`, "The layer imports check"). For the core
and each package a gate step runs over (`editorPackages`), each module of
its libraries and each module of a package of the workspace it imports
directly, its own package's included, one line, its fields separated by
tabs: the package's name and layer (`layerOf`), the importing module, the
imported module's package and layer, and the imported module. A module of
the toolchain is no module of the workspace, and is not listed. The imports
within one package are listed so that the check can see the core's modules
were walked: every core module that imports another core module gives a
line whose importer's layer is `core`. A module two of a package's
libraries hold is listed once. It reads each module's header, as Lake does
to resolve imports, and builds nothing. -/
package_facet editorLayerImports pkg : Array String := do
  let ws ← getWorkspace
  let mut jobs : Array (Job (Array String)) := #[]
  for dep in setPackages ws pkg do
    if !dep.remoteUrl.isEmpty || dep.leanLibs.isEmpty then
      continue
    let name := dep.baseName.toString (escape := false)
    let layer := layerOf dep
    for lib in dep.leanLibs do
      let job ←
        (← lib.modules.fetch).bindM fun mods => do
          let lines ←
            mods.mapM fun mod => do
              (← mod.imports.fetch).mapM fun imports =>
                return imports.map fun imported =>
                    s!"{name}\t{layer}\t{mod.name}\t{imported.pkg.baseName.toString (escape := false)}\t{layerOf imported.pkg}\t{imported.name}"
          return (Job.collectArray lines).map (·.flatten)
      jobs := jobs.push job
  return (Job.collectArray jobs).map fun lines => Id.run do
    let mut seen : Std.HashSet String := {}
    let mut kept : Array String := #[]
    for line in lines.flatten do
      unless seen.contains line do
        seen := seen.insert line
        kept := kept.push line
    return kept

/-- The packages of a set as a graph, for the pre-commit hook
(`tools/hook-targets.sh`; `lake -d <set dir> query :editorPackageGraph`;
`docs/dev-practices/the-gate.md`, "The pre-commit hook"). For each package
a gate step runs over (`editorPackages`), in the same order, each after the
packages it requires, one line, its fields separated by tabs: its name, its
layer (`layerOf`), its directory, and the names of the packages it requires
directly that are themselves such packages, separated by spaces, or `-`
when there is none (the core is never one). It builds nothing. -/
package_facet editorPackageGraph pkg : Array String := do
  let ws ← getWorkspace
  let isGatePackage (dep : Package) : Bool :=
    dep.keyName != __name__ && dep.remoteUrl.isEmpty && !dep.leanLibs.isEmpty
  let mut lines : Array String := #[]
  for dep in setPackages ws pkg do
    unless isGatePackage dep do
      continue
    let required :=
      dep.depConfigs.filterMap fun cfg =>
        match ws.findPackageByName? cfg.name with
        | some req =>
          if isGatePackage req then some (req.baseName.toString (escape := false)) else none
        | none => none
    let requires := if required.isEmpty then "-" else " ".intercalate required.toList
    lines :=
      lines.push s!"{dep.baseName.toString (escape := false)}\t{layerOf dep}\t{dep.dir}\t{requires}"
  return Job.pure lines

/-- The checks of the boundary with the Rust library (`FfiTest.lean`), linked
exactly like the editor (`linkAsEditor`): `supportInterpreter` exports the
executable's symbols, so interpreted config can find compiled definitions
and `@[extern]` symbols, and the glue, the Rust archive and `linkArgs` are
the same. `mise run ffi-test` runs it. -/
@[default_target] lean_exe «ffi-test» where
  root := `FfiTest
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs.push coreSystemLibraries

/-- The checks of the config session against the real elaborator
(`ConfigTest.lean`), linked exactly like the editor, as `ffi-test` is.
`mise run ffi-test` runs it. It also holds the benchmark `mise run config-bench` runs. -/
@[default_target] lean_exe «config-test» where
  root := `ConfigTest
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
\t<string>leanmacs</string>
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
`editorApp` makes each from the artwork (`appIconFile`) with `sips`, and
`mise run app-check` finds exactly these in the built icon. -/
def appIconSizes : List (String × Nat) :=
  [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)]

/-- `Leanmacs.app`, the editor of a package set as a macOS app bundle, at
`<set>/.lake/build/Leanmacs.app`: `lake -d <set dir> build :editorApp`
(`mise run app`, on the default set; `docs/dev-practices/building.md`, "The
app bundle"). It is a facet of the set, as `editor` is, and nothing builds
it by default: the gate never does, and it is refused with the reason
anywhere but macOS on arm64 (`requireArm64Mac`).

`pkg` is the set, which holds the bundle, its trace, its staging directory
and its list of shipped files in its build directory. Everything else it
reads is the core's, this package's, found in the workspace by name: the
stage script, this lakefile, the version file and the artwork.

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
`tools/stage-bundle.sh` from what `editorShipped` lists, as `bundle-test`
lays them out; `Contents/Info.plist`
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
the stage script's, this lakefile's, the version file's and the artwork's traces with
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
package_facet editorApp pkg : FilePath := do
  requireArm64Mac
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  let exe ← fetch <| pkg.facet `editor
  let launcherJob ← launcher.fetch
  -- What the bundle ships of the set, built.
  let shippedJob ← fetch <| pkg.facet `editorShipped
  let stager ← inputTextFile <| core.dir / ".." / "tools" / "stage-bundle.sh"
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
          proc (quiet := true)
              { cmd := stager.toString
                args :=
                  #["--launcher", launcherFile.toString, staged.toString, exe.toString,
                    sysroot.toString, list.toString] }
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

/-- The model tests (`ModelTest.lean`, which imports its modules under
`ModelTest/`): `lake test` builds and runs this (`mise run lean-test`). It
is not a default target and links no glue and no Rust archive, so nothing it
needs reaches `rustlib`. `-L`: as in `linkArgs`, so it links under either
compiler. It starts at Lean's `main`. -/
@[test_driver] lean_exe «model-test» where
  root := `ModelTest
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
lean_lib ModelTests where globs := #[.submodules `ModelTest]

/-- The `ffi-test` executable's modules (`FfiTest/**/*.lean`: the test
modules under `FfiTest/Editor/`, the support modules under `FfiTest/Support/`
and `FfiTest/Check.lean`), which its root `FfiTest.lean` imports. Lake
resolves an import only to a module of a library, never to one of an
executable's, so these need a library of their own. It is not a default
target: the `ffi-test` executable, which is, imports it, so `lake build`
builds it and links its objects in. `.submodules` takes every module under
`FfiTest`, at any depth, and not `FfiTest` itself, so the executable's root
belongs to no library. -/
lean_lib FfiTests where globs := #[.submodules `FfiTest]

/-- The `contract-test` executable's modules (`ContractTest/**/*.lean`: the
test modules under `ContractTest/Editor/`, the support modules under
`ContractTest/Support/` and `ContractTest/Check.lean`), which its root
`ContractTest.lean` imports. Lake resolves an import only to a module of a
library, never to one of an executable's, so these need a library of their
own. It is not a default target: the `contract-test` executable, which is,
imports it, so `lake build` builds it and links its objects in.
`.submodules` takes every module under `ContractTest`, at any depth, and
not `ContractTest` itself, so the executable's root belongs to no library. -/
lean_lib ContractTests where globs := #[.submodules `ContractTest]

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
lean_lib ConfigTests where globs := #[.submodules `ConfigTest]

/-- The contract checks of the text port and of the job port against their
real bindings (`ContractTest.lean`), linked like the editor with the glue and
the Rust archive. `mise run ffi-test` runs it. It interprets nothing, so it
does not export its symbols. -/
@[default_target] lean_exe «contract-test» where
  root := `ContractTest
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs.push coreSystemLibraries

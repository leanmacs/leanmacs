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
(`docs/design/packages.md`, "The package set and its build"). -/
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

/-- Links an executable at `file`, rooted at the module `root`, as the
editor is linked: `root`'s object and those of every module it imports,
with their symbols exported, so interpreted config can find compiled
definitions and `@[extern]` symbols (`-rdynamic`, what `supportInterpreter`
gives a `lean_exe`); then the glue and the Rust archive; then `linkArgs`.
`root` may be a module of any package of the workspace: the glue and the
archive are this package's targets, built in its build directory. -/
def linkAsEditor (root : Module) (file : FilePath) : FetchM (Job FilePath) := do
  let infoJob ← root.linkInfoExport.fetch
  let glueJob ← glue.o.fetch
  let rustJob ← rustlib.fetch
  ((infoJob.zipWith Prod.mk glueJob).zipWith Prod.mk rustJob).mapM fun ((info, glue), rust) => do
      addPureTrace linkArgs "linkArgs"
      buildLeanExeSync file ((info.objs.push glue).push rust) info.libs
          (#["-rdynamic"] ++ info.args ++ linkArgs)

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

/-- The text of a set's root module, for the entry modules `entries` in the
order they register and the config base `base` (`setBase`). It imports the
core's base, `Editor`, for the link alone (`Editor/Main.lean`, "This module
names no package, and not the config base"), then the executable's entry,
then each entry module; and its `main` is one call of `Editor.Main.run`
with the entry modules' `packages` appended in that order, and the base as
an array of names. Every module of the base is among its imports, so each
is linked into the executable, which the elaborator requires of a module it
imports at runtime. -/
def rootSource (entries base : Array Name) : String :=
  let imports := entries.foldl (fun text name => text ++ s!"import {name}\n") ""
  let lists :=
    if entries.isEmpty then "#[]"
    else " ++ ".intercalate (entries.map fun name => s!"{name}.packages").toList
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

/-- The editor, with the packages of the set's Lake packages, and the
modules config is elaborated on: `Editor`, then the entry module of each
package of the set outside the core. -/
def main (args : List String) : IO UInt32 :=
  Editor.Main.run ({lists}) #[{names}] args
"

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

/-- The name of the root module the package-set build generates. No library
declares it. -/
def setRootName : Name :=
  `EditorSetRoot

/-- The entry modules of the set `pkg`, in the order they register
(`setPackages`, `entryModule?`), each with whether its Lake package is this
one, the core. -/
def setEntries (pkg : Package) : FetchM (Array (Bool × Name)) := do
  let ws ← getWorkspace
  let mut entries : Array (Bool × Name) := #[]
  for dep in setPackages ws pkg do
    match ← entryModule? dep with
    | some mod =>
      entries := entries.push (dep.keyName == __name__, mod.name)
    | none =>
      pure ()
  return entries

/-- The config base of a set, from its entry modules (`setEntries`): the
modules its editor elaborates config on. `Editor`, the core's base
(`Editor.lean`), then the entry module of each package of the set outside
the core, in the order they register, so that config can name what a
package of the set declares: an entry module imports its package's modules.
The core's own entry module is not in it: the core's base is `Editor`, and
what config sees of the core does not change with the set
(`docs/design/packages.md`, "The package set and its build"). -/
def setBase (entries : Array (Bool × Name)) : Array Name :=
  #[`Editor] ++ (entries.filter (!·.1)).map (·.2)

/-- The root module of the set `pkg`, written from the entry modules of the
set's packages (`setEntries`, `setBase`, `rootSource`) to
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
  writeIfChanged root.leanFile (rootSource (entries.map (·.2)) (setBase entries))
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

/-- The editor of a package set: `lake -d <set dir> build :editor` gives
`<set>/.lake/build/bin/editor`.

A package set is a Lake package whose `require`s are the set; its lakefile
declares no target. This facet is the package-set build
(`docs/design/packages.md`, "The package set and its build"): it writes
the set's root module (`setRoot`), builds it with every module it imports,
each in its own package's build directory, and links it as the editor is
linked (`linkAsEditor`). Beside the executable it records where the
`.olean` files of the set's packages are (`writeModuleRecord`), which an
editor run directly reads. It is defined here because the link's objects and
arguments are the core's knowledge, and a lakefile cannot import another's
definitions; a facet reaches every package of a workspace that holds this
one.

It is the only way an editor is built: this package declares no `editor`
executable, and no root module is written by hand. The executable imports
the config session, so Lean's elaborator is linked in. -/
package_facet editor pkg : FilePath := do
  let executable := pkg.binDir / "editor"
  writeModuleRecord pkg executable
  linkAsEditor (← setRoot pkg) executable

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
generated root hands `Editor.Main.run`, and what the bundle's module files
are the closure of (`editorApp`, `mise run bundle-test`). It reads no
source and builds nothing. -/
package_facet editorBase pkg : Array String := do
  return Job.pure ((setBase (← setEntries pkg)).map (·.toString))

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
  linkAsEditor mod (linkedFile mod)

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

/-- The checks of the boundary with the Rust library (`FfiTest.lean`), linked
exactly like the editor (`linkAsEditor`): `supportInterpreter` exports the
executable's symbols, so interpreted config can find compiled definitions
and `@[extern]` symbols, and the glue, the Rust archive and `linkArgs` are
the same. `mise run ffi-test` runs it. -/
@[default_target] lean_exe «ffi-test» where
  root := `FfiTest
  supportInterpreter := true
  moreLinkObjs := #[glue.o, rustlib]
  moreLinkArgs := linkArgs

/-- The checks of the config session against the real elaborator
(`ConfigTest.lean`), linked exactly like the editor, as `ffi-test` is.
`mise run ffi-test` runs it. It also holds the benchmark `mise run config-bench` runs. -/
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

/-- `Leanmacs.app`, the editor of a package set as a macOS app bundle, at
`<set>/.lake/build/Leanmacs.app`: `lake -d <set dir> build :editorApp`
(`mise run app`, on the default set; `docs/dev-practices/building.md`, "The
app bundle"). It is a facet of the set, as `editor` is, and nothing builds
it by default: the gate never does, and it is refused with the reason
anywhere but macOS on arm64 (`requireArm64Mac`).

`pkg` is the set, which holds the bundle, its trace, its staging directory
and its closure file in its build directory. Everything else it reads is
the core's, this package's, found in the workspace by name: the stage
script, this lakefile, the version file, the artwork and the `.olean`
directory.

It holds `Contents/MacOS/editor`, a copy of the set's `editor`; under
`Contents/Resources/lean`, the `.olean`, `.olean.server` and
`.olean.private` files of the modules the set's config base imports
(`setBase`; the closure `config-test bench-modules` lists, over the set's
`.olean` directories, `moduleDirectories`), from the toolchain Lake runs
on, which is the pinned one, and from the core and each package of the set
whose modules the base holds, all in the bundle's one directory, laid out
by `tools/stage-bundle.sh` as `bundle-test` lays them out; `Contents/Info.plist`
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
package_facet editorApp pkg : FilePath := do
  requireArm64Mac
  let some core := (← getWorkspace).findPackageByKey? __name__
    | error "the core's package is not in the workspace"
  -- The set's config base and the directories its modules are in, which
  -- the bundle's module files are the closure of and are copied from.
  let base := (setBase (← setEntries pkg)).map (·.toString)
  let searched := ":".intercalate ((← moduleDirectories pkg).map (·.toString)).toList
  let exe ← fetch <| pkg.facet `editor
  let lister ← «config-test».fetch
  let library ← Editor.fetch
  let stager ← inputTextFile <| core.dir / ".." / "tools" / "stage-bundle.sh"
  -- This file is the recipe, so a change to it rebuilds the bundle too.
  let recipe ← inputTextFile <| core.dir / "lakefile.lean"
  let versionJob ← inputTextFile <| core.dir / appVersionFile
  let artJob ← inputBinFile <| core.dir / appIconFile
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
                  args := #["bench-modules", sysroot.toString, searched] ++ base }
          IO.FS.writeFile closure (modules ++ "\n")
          proc (quiet := true)
              { cmd := stager.toString
                args :=
                  #["--closure", closure.toString, staged.toString, exe.toString, sysroot.toString,
                    searched, "olean", "olean.server", "olean.private"] }
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
  moreLinkArgs := linkArgs

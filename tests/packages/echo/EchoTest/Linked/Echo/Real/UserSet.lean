import Echo.Real
import EchoTest.Check
import Editor.PackageLibrary
import Editor.PackageSet.Build
import Editor.PackageSet.Running
import Editor.RealHost
import Editor.Restore.Restart
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees

/-!
# Linked tests: a user's set with echo builds with no Cargo, and its editor loads echo's library from the set's build

A user's set is a set outside the repository, so its Rust archive is the
core's as it is built (`rustSource` in `lean/lakefile.lean`: `prebuilt`)
and no Cargo runs for it; a package whose native code is a library of its
own adds nothing there. These checks build such a set with the toolchain's
`lake` the linked test is handed, the one the app bundles and its build
job runs, through the real process port, in a temporary directory of the
check's own, with no `cargo` on the child's `PATH`
(docs/design/packages.md, "A package's library, staged and loaded, as
built"):

- **A prebuilt library builds with no Cargo, and loads from the set's
  build.** A copy of echo (`.lake` left out) holds the library this linked
  test loaded (`Editor.PackageLibrary.staged "echo" "echo"`) at
  `lib/libecho_service.<ext>`,
  so its `editorLibrary` target answers it and runs no process; its core
  require names the repository's core. A set requiring the default set,
  the copy and the core last, as a user's config does, resolves with
  `lake update --keep-toolchain` and builds with `lake build :editor`,
  both exiting 0: any Cargo run would fail to spawn and fail the build.
  Then the copy, the package's whole source directory, is removed, the
  set's `editor.libraries` names the library staged under the set's build
  directory, and that editor's `--probe` passes the build's own judgement
  (`Editor.Restore.probeFailure`), which it reaches only once echo's
  initialiser loaded its library, from there.
- **A library that must be built, with its tool missing, stops the build
  naming the package and the tool.** A second copy of echo, with no
  `lib/`, whose target then runs `cargo`, in a set of its own requiring
  only it and the core: `lake build :editorLibraries` exits non-zero, and
  the build job's reading of its lines (`PackageSet.missingTooling?`)
  answers the core's sentence for echo and cargo, so Lake's real line and
  the reader are held to each other.

**The child's environment** is the build job's shape
(`PackageSet.Order.environmentOf`): the user's Lean, Lake and compiler
variables removed (`PackageSet.clearedVariables`), then the fixture set's
build record (`editor.build`, read with `PackageSet.buildIn`) set over
them, with `PATH=/usr/bin:/bin` and a `HOME` of the check's own, so
nothing reads the developer's PATH or home. That `cargo` is in neither
directory is checked first: on a machine where it is, the check fails
saying it cannot show the property, rather than passing.

**What it writes outside its directory** is only what the core's and the
default set's builds would write in place, which `mise run lean` built
just before. Its directory is removed only once a flush of the process
service has completed (`Editor.Test.Linked.withFlushedBase`), so nothing
still runs in it. Each run's completion is waited for on the run itself,
the bound a hang guard.

The linked test runs in the package's directory (`tools/package-set.sh`),
so echo's source and the repository are found from there.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EchoTest.Linked.Echo.Real.UserSet : Editor.WiringSet :=
  .wiring
    "the toolchain's lake and the editor it builds, run through the real process port on a user's set in a temporary directory of its own"
    "only a real build shows which tools a set's build runs, and only a real executable loads a staged library; no fake builds a set or starts an editor"

namespace EchoTest.Linked

open Editor

/-- The `PATH` the builds run with: the system's directories alone, which
hold no `cargo` on a developer's Mac or on the CI runner. -/
def userSetPath : String :=
  "/usr/bin:/bin"

/-- The directories a `PATH` names, in order. -/
def pathEntries (path : String) : List String :=
  (path.splitOn ":").filter (!·.isEmpty)

/-- How long a build of a user's set may take before the check fails as a
hang, never a result: the set's root and the copy of echo are compiled and
the editor linked, about 8 s on a developer's Mac (2026-11-27, Apple M5
Max) with the default set and the core built, and a cold build of the copy
under the stress loop's load several times that; ten minutes. -/
def userSetBuildGuard : HangGuard :=
  .on "lake's build of a user's set" 600000

/-- The most bytes of a run's output kept. -/
def userSetOutputLimit : Nat :=
  16777216

/-- The library file a build of echo makes on this platform. -/
def echoLibraryFile : String :=
  s!"libecho_service.{if System.Platform.isOSX then "dylib" else "so"}"

/-- Copies the directory `source` into `copy`, each file's bytes, links
followed, leaving out Lake's and the formatter's own directories. -/
partial def copyPackage (source copy : System.FilePath) : IO Unit := do
  IO.FS.createDirAll copy
  for entry in ← source.readDir do
    if entry.fileName == ".lake" || entry.fileName == ".lean-fmt-cache" then
      continue
    if ← entry.path.isDir then
      copyPackage entry.path (copy / entry.fileName)
    else
      IO.FS.writeBinFile (copy / entry.fileName) (← IO.FS.readBinFile entry.path)

/-- The line echo's lakefile requires the core by, relative to the package
in the repository. -/
def echoCoreRequire : String :=
  "require «editor-core» from \"..\" / \"..\" / \"..\" / \"lean\""

/-- Copies echo, from the working directory, into `copy`, its core required
from `core`, absolute, in its lakefile and its manifest; with `library`,
that library at `lib/` of the copy. Throws when the lakefile holds no line
to replace. -/
def copyEcho (copy core : System.FilePath) (library : Option String) : IO Unit := do
  copyPackage "." copy
  let lakefile ← IO.FS.readFile (copy / "lakefile.lean")
  unless (lakefile.splitOn echoCoreRequire).length == 2 do
    throw (IO.userError s!"echo's lakefile has no line {echoCoreRequire} to point at {core}")
  IO.FS.writeFile (copy / "lakefile.lean")
      (lakefile.replace echoCoreRequire s!"require «editor-core» from \"{core}\"")
  let manifest ← IO.FS.readFile (copy / "lake-manifest.json")
  IO.FS.writeFile (copy / "lake-manifest.json")
      (manifest.replace "\"../../../lean\"" s!"\"{core}\"")
  if let some library := library then
    IO.FS.createDirAll (copy / "lib")
    IO.FS.writeBinFile (copy / "lib" / echoLibraryFile) (← IO.FS.readBinFile library)

/-- The `lakefile.toml` of a user's set named `name` requiring `required`,
each a name and a directory, in order. -/
def userSetLakefile (name : String) (required : List (String × System.FilePath)) : String :=
  required.foldl
    (fun text (package, directory) =>
      text ++ s!"\n[[require]]\nname = \"{package}\"\npath = \"{directory}\"\n")
    s!"name = \"{name}\"\n"

/-- The environment the builds run with, over the test's own: the build
job's shape, with the fixture set's build record `record`, the system's
`PATH` and the home `home`. -/
def userSetEnvironment (record : String) (home : System.FilePath) : Process.Environment :=
  { unset := PackageSet.clearedVariables
    set := PackageSet.buildIn record ++ #[("PATH", userSetPath), ("HOME", home.toString)] }

/-- Runs `command` through `services`' real process port to its end, waited
for on its completion within `userSetBuildGuard`: what it wrote and how it
ended, or how it failed. -/
def runToEnd (services : Editor.Test.Linked.Services) (command : Process.Command) :
    IO (Except String Process.Ran) := do
  let request := ProcessRequest.run command userSetOutputLimit
  let (id, wait) ← services.completions.register
  services.jobs.processes.start id request
  -- Waited for on the run's own completion; the bound is a hang guard.
  let ended ← Job.awaitWithin userSetBuildGuard wait.result?
  unless ended == some (some .completed) do
    return .error s!"the run of {command.program} did not complete: {repr ended}"
  match ← services.jobs.processes.take id request with
  | .ok ran =>
    return .ok ran
  | .error error =>
    return .error error.describe

/-- The lines a run wrote, standard output's then standard error's. -/
def ranLines (ran : Process.Ran) : List String :=
  ((String.fromUTF8! ran.stdout).splitOn "\n") ++ (String.fromUTF8! ran.stderr).splitOn "\n"

/-- The last `count` lines a run wrote, for a failure's message. -/
def ranTail (ran : Process.Ran) (count : Nat := 30) : String :=
  let lines := (ranLines ran).filter (!·.isEmpty)
  "\n".intercalate (lines.drop (lines.length - count))

/-- Runs `lake` at `lake` with `arguments` in `directory`, with
`environment`, and passes when it exits 0. -/
def lakeSucceeds (services : Editor.Test.Linked.Services) (lake : String)
    (environment : Process.Environment) (directory : System.FilePath) (arguments : Array String) :
    IO (Except String Unit) := do
  match ← runToEnd services { program := lake, arguments, environment, directory } with
  | .error how =>
    return .error how
  | .ok { exit := .code 0, .. } =>
    return .ok ()
  | .ok ran =>
    return .error
        s!"lake {" ".intercalate arguments.toList} in {directory} ended {repr ran.exit}:\n{ranTail ran}"

/-- Why this machine cannot show the property: a `cargo` in a directory of
`userSetPath`; none when there is none. -/
def cargoOnUserPath? : IO (Option String) := do
  for directory in pathEntries userSetPath do
    let cargo : System.FilePath := directory / "cargo"
    if ← cargo.pathExists then
      return some
          s!"{cargo} is on the PATH the check builds with ({userSetPath}), so this machine cannot show a build with no Cargo"
  return none

/-- The checks of a user's set holding echo, built with the toolchain's
`lake` under `sysroot` through `services`' real process port, each in a
temporary directory of its own. -/
def echoUserSetChecks (sysroot : String) (services : Editor.Test.Linked.Services) : List Check :=
  let lake := (System.FilePath.mk sysroot / "bin" / "lake").toString
  [{  name :=
        "a user's set outside the repository whose package declares a library already built builds with the toolchain's lake, with no cargo on PATH, and its editor loads the library from the set's build once the package's source directory is removed"
      run :=
        Editor.Test.Linked.withFlushedBase services.jobs fun tmp => do
          if let some reason← cargoOnUserPath? then
            return ← saw false reason
          let repo ← IO.FS.realPath (".." / ".." / "..")
          let record ←
            IO.FS.readFile
                (repo / "tests" / "packages" / ".lake" / "build" / "bin" / "editor.build")
          let home := tmp / "home"
          IO.FS.createDirAll home
          let environment := userSetEnvironment record home
          let echo := tmp / "echo"
          copyEcho echo (repo / "lean") (some (← Editor.PackageLibrary.staged "echo" "echo"))
          let set := tmp / "set"
          IO.FS.createDirAll set
          IO.FS.writeFile (set / "lakefile.toml")
              (userSetLakefile "user-set"
                [("default-set", repo / "packages"), ("echo", echo),
                  ("editor-core", repo / "lean")])
          if let .error how←
              lakeSucceeds services lake environment set #["update", "--keep-toolchain"] then
            return ← saw false how
          if let .error how← lakeSucceeds services lake environment set #["build", ":editor"] then
            return ← saw false how
          IO.FS.removeDirAll echo
          let editor := set / ".lake" / "build" / "bin" / "editor"
          let staged := set / ".lake" / "build" / "libraries" / "echo" / echoLibraryFile
          let libraries ← IO.FS.readFile (editor.toString ++ ".libraries")
          unless libraries == s!"echo\t{staged}\n" do
            return ←
                saw false
                    s!"the set's editor.libraries holds {repr libraries}, not echo's library at {staged}"
          match
            ←
              runToEnd services
                  { program := editor.toString, arguments := #["--probe"], directory := "/" } with
          | .error how =>
            saw false how
          | .ok ran =>
            let failure := Editor.Restore.probeFailure ran
            saw (failure == none)
                s!"the set's editor, with echo's source removed: {failure.getD ""}" },
    { name :=
        "a user's set whose package's library must be built with cargo, and has no cargo on PATH, stops naming echo and cargo"
      run :=
        Editor.Test.Linked.withFlushedBase services.jobs fun tmp => do
          if let some reason← cargoOnUserPath? then
            return ← saw false reason
          let repo ← IO.FS.realPath (".." / ".." / "..")
          let record ←
            IO.FS.readFile
                (repo / "tests" / "packages" / ".lake" / "build" / "bin" / "editor.build")
          let home := tmp / "home"
          IO.FS.createDirAll home
          let environment := userSetEnvironment record home
          let echo := tmp / "echo"
          copyEcho echo (repo / "lean") none
          let set := tmp / "set"
          IO.FS.createDirAll set
          IO.FS.writeFile (set / "lakefile.toml")
              (userSetLakefile "user-set" [("echo", echo), ("editor-core", repo / "lean")])
          if let .error how←
              lakeSucceeds services lake environment set #["update", "--keep-toolchain"] then
            return ← saw false how
          match
            ←
              runToEnd services
                  { program := lake, arguments := #["build", ":editorLibraries"], environment,
                    directory := set } with
          | .error how =>
            saw false how
          | .ok ran =>
            let said := (ranLines ran).findSome? PackageSet.missingTooling?
            let expected := "cargo is required to build echo's library, and none works here ("
            saw (ran.exit != .code 0 && (said.map (·.startsWith expected)) == some true)
                s!"the build ended {repr ran.exit} and said {repr said}:\n{ranTail ran}" }]

end EchoTest.Linked

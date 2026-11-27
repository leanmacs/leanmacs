import Editor.PackageSet.Build
import Editor.PackageSet.Running
import Editor.Process
import Editor.Test.Linked.Services

/-!
# The linked test kit: UserSet

What a package's linked check needs to build a user's set, a set outside
the repository, with the toolchain's `lake` through the real process
port, in a temporary directory of its own, with no `cargo` on the child's
`PATH` (docs/design/packages.md, "A package's library, staged and loaded,
as built"): the `PATH` it builds with (`userSetPath`) and the check that
no `cargo` is on it (`cargoOnUserPath?`); a copy of a package's source
(`copyPackage`), its requires pointed at absolute directories
(`repointRequires`); a set's `lakefile.toml` (`userSetLakefile`); the
build job's environment over the fixture set's build record
(`userSetEnvironment`); and a run to its end on the real process port,
waited for on its completion under a hang guard (`runToEnd`,
`lakeSucceeds`), with the lines it wrote (`ranLines`, `ranTail`).

Moved from echo's user-set check (`EchoTest/Linked/Echo/Real/UserSet.lean`)
in phase 5 of `package-native-libraries`, so acp's installed-set check is
written on the same helpers and no package's test imports another
package's.

Published for a package's linked test: it is a module of the core's linked
test kit, in the namespace `Editor.Test.Linked`, which the root of a
package's linked test and the modules under it may import, and no other
module of a package may (`docs/design/packages.md`, "What a package may
import"). It holds no checks of its own, and starts no service: each
helper that runs a process is handed the services a wiring module's check
started.
-/

namespace Editor.Test.Linked

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

/-- A require of a copied package, pointed elsewhere (`repointRequires`):
its line in the copy's `lakefile.lean`, the directory its path entry names
in the copy's `lake-manifest.json`, as written there, and the absolute
directory it is to name instead. -/
structure Repoint where
  /-- The require's line in the lakefile, whole, as
  `require «editor-core» from ".." / ".." / "lean"`. -/
  line : String
  /-- The directory its manifest entry names, as `../../lean`. -/
  relative : String
  /-- The directory it is to name. -/
  directory : System.FilePath

/-- `text` with `part` replaced by `replacement`, when `part` occurs in it
exactly once; none otherwise. -/
def replaceOnce? (text part replacement : String) : Option String :=
  if (text.splitOn part).length == 2 then some (text.replace part replacement) else none

/-- Points each require of `repoints` of the copied package at `copy` at
its absolute directory: its line in `lakefile.lean` becomes
`<line up to " from "> from "<directory>"`, and its entry's directory in
`lake-manifest.json` the same directory. Each line and each entry must
occur exactly once, or it throws, naming it, so a copy whose lakefile
changed fails its check rather than build against the repository's
relative paths. -/
def repointRequires (copy : System.FilePath) (repoints : List Repoint) : IO Unit := do
  let mut lakefile ← IO.FS.readFile (copy / "lakefile.lean")
  let mut manifest ← IO.FS.readFile (copy / "lake-manifest.json")
  for repoint in repoints do
    let head := (repoint.line.splitOn " from ").headD repoint.line
    let some edited := replaceOnce? lakefile repoint.line s!"{head} from \"{repoint.directory}\""
      |
      throw
          (IO.userError
            s!"{copy}/lakefile.lean holds the line {repoint.line} not exactly once, to point at {repoint.directory}")
    lakefile := edited
    let some entry := replaceOnce? manifest s!"\"{repoint.relative}\"" s!"\"{repoint.directory}\""
      |
      throw
          (IO.userError
            s!"{copy}/lake-manifest.json names the directory {repoint.relative} not exactly once, to point at {repoint.directory}")
    manifest := entry
  IO.FS.writeFile (copy / "lakefile.lean") lakefile
  IO.FS.writeFile (copy / "lake-manifest.json") manifest

/-- The `lakefile.toml` of a user's set named `name` requiring `required`,
each a name and a directory, in order. -/
def userSetLakefile (name : String) (required : List (String × System.FilePath)) : String :=
  required.foldl
    (fun text (package, directory) =>
      text ++ s!"\n[[require]]\nname = \"{package}\"\npath = \"{directory}\"\n")
    s!"name = \"{name}\"\n"

/-- The environment the builds run with, over the test's own: the build
job's shape (`PackageSet.Order.environmentOf`), with the fixture set's
build record `record`, the system's `PATH` and the home `home`. -/
def userSetEnvironment (record : String) (home : System.FilePath) : Process.Environment :=
  { unset := PackageSet.clearedVariables
    set := PackageSet.buildIn record ++ #[("PATH", userSetPath), ("HOME", home.toString)] }

/-- Runs `command` through `services`' real process port to its end, waited
for on its completion within `userSetBuildGuard`: what it wrote and how it
ended, or how it failed. -/
def runToEnd (services : Services) (command : Process.Command) : IO (Except String Process.Ran) :=
  do
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
def lakeSucceeds (services : Services) (lake : String) (environment : Process.Environment)
    (directory : System.FilePath) (arguments : Array String) : IO (Except String Unit) := do
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

end Editor.Test.Linked

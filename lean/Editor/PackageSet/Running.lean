import Editor.PackageSet.Fingerprint

/-!
# What the running editor knows of its own package set

The facts a user's package-set build starts from that only the running
executable knows (`docs/design/packages.md`, "User package sets"): which
set it was linked from (its fingerprint), which core it links (`editor.core`),
the environment its link ran with (`editor.build`), where its config and
data directories are, and the `lake` of its toolchain. An executable host
reads them once, at the edge, beside the executable (`at`, over a file read
and a test of existence it is handed), and sets them in the editor state
(`EditorState.packageSet`) and in its reload's package port; nothing
changes them after.

## The records beside the executable

- **`<executable>.core`**: one line, the core's identity (`coreIn`).
- **`<executable>.build`**: one `NAME=value` a line (`buildIn`).
- **`<executable>.packages`**: the fingerprint a per-user install was built
  from (`Fingerprint.parse?`). An executable with none, built from a set
  directory, has the shipped fingerprint of that set
  (`PackageSet.shipped`), when it knows the set's directory; with neither it
  has none, and never starts a build.

In a bundle the records are beside `Contents/MacOS/editor`, as outside one.

Pure over its two ports, so `model-test` pins it
(`ModelTest.packageSetRunningChecks`).
-/

namespace Editor.PackageSet

/-- What the running editor knows of its own package set ("What the running
editor knows of its own package set", in the module docs). -/
structure Running where
  /-- The running executable's path; empty when it is not known. -/
  executable : String := ""
  /-- The config directory, absolute; empty for a host with none. -/
  config : String := ""
  /-- The fingerprint of the set it was linked from; none when it is not
  known. -/
  fingerprint : Option Fingerprint := none
  /-- The core's identity, from `<executable>.core`. -/
  core : Option String := none
  /-- The environment its link ran with, from `<executable>.build`. -/
  build : Array (String × String) := #[]
  /-- The Lean toolchain's directory, if one is known. -/
  sysroot : Option String := none
  /-- `<sysroot>/bin/lake`, when that file is there. -/
  lake : Option String := none
  /-- The user's data directory: where per-user editors are installed
  (`Editor/PackageSet/Layout.lean`); none for a host that has none. -/
  data : Option String := none
  deriving DecidableEq, Repr, BEq, Inhabited

/-- The record of the core's identity beside the executable at `appPath`. -/
def coreRecordPath (appPath : String) : String :=
  appPath ++ ".core"

/-- The record of the build environment beside the executable at
`appPath`. -/
def buildRecordPath (appPath : String) : String :=
  appPath ++ ".build"

/-- The record of the fingerprint beside a per-user executable at
`appPath`. -/
def packagesRecordPath (appPath : String) : String :=
  appPath ++ ".packages"

/-- The identity a `.core` record's text holds: its first line that is not
blank, without the white space around it. -/
def coreIn (text : String) : Option String :=
  ((text.splitOn "\n").map (·.trimAscii.toString)).find? (!·.isEmpty)

/-- The variables a `.build` record's text holds: each line `NAME=value`,
in order; a line with no `=` is left out. -/
def buildIn (text : String) : Array (String × String) :=
  ((text.splitOn "\n").filterMap fun line =>
      match line.splitOn "=" with
      | name :: value :: rest =>
        if name.isEmpty then none else some (name, "=".intercalate (value :: rest))
      | _ => none).toArray

/-- What the executable at `appPath` knows of its set, read through
`readFile`, which answers a file's text or none, and `exists`, which says
whether a file is there: its records, the set it was built from (`set`,
the set's Lake name and directory, when it knows them), its config
directory `config`, its toolchain directory `sysroot` and its data
directory `data`. -/
def «at» {m : Type → Type} [Monad m] (appPath : String) (config : String)
    (set : Option (String × String)) (sysroot data : Option String)
    (readFile : String → m (Option String)) (exists_ : String → m Bool) : m Running := do
  let recorded := (← readFile (packagesRecordPath appPath)).bind Fingerprint.parse?
  let fingerprint := recorded <|> set.map fun (name, directory) => shipped name directory
  let core := (← readFile (coreRecordPath appPath)).bind coreIn
  let build := ((← readFile (buildRecordPath appPath)).map buildIn).getD #[]
  let lake ←
    match sysroot with
    | some root =>
      let candidate := root ++ "/bin/lake"
      pure (if ← exists_ candidate then some candidate else none)
    | none =>
      pure none
  return { executable := appPath, config, fingerprint, core, build, sysroot, lake, data }

/-- The shipped set's Lake name, as the running editor knows it: its
fingerprint's. -/
def Running.setName (running : Running) : Option String :=
  running.fingerprint.bind (·.set)

end Editor.PackageSet

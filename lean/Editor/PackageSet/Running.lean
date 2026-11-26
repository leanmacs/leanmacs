import Editor.PackageSet.Fingerprint

/-!
# What the running editor knows of its own package set

The facts a user's package-set build starts from that only the running
executable knows (`docs/design/packages.md`, "User package sets"): which
set it was linked from (its fingerprint), which core it links (`editor.core`) and from which directory
(`ModuleLookup.coreDirectory?`, which the host reads and hands in),
the environment its link ran with (`editor.build`), where its config and
data directories are, and the `lake` of its toolchain. An executable host
reads them once, at the edge, beside the executable (`at`, over a file read
and a test of existence it is handed), and sets them in the editor state
(`EditorState.packageSet`) and in its reload's package port; nothing
changes them after, but what each reload reads of the config (`facts`).

## The records beside the executable

- **`<executable>.core`**: one line, the core's identity (`coreIn`).
- **`<executable>.build`**: one `NAME=value` a line (`buildIn`).
- **`<executable>.packages`**: the fingerprint a per-user install was built
  from (`Fingerprint.parse?`). An executable with none, built from a set
  directory, has the shipped fingerprint of that set
  (`PackageSet.shipped`), when it knows the set's directory; with neither it
  has none, and never starts a build.

In a bundle the core's and the build's records are
`Contents/Resources/editor.core` and `Contents/Resources/editor.build`
(`coreRecordPath`, `buildRecordPath`): `codesign` refuses a file in
`Contents/MacOS` that is not code.

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
  /-- The directory of the core it is linked from, absolute and normalised
  (`ModuleLookup.coreDirectory?`): what the lakefile's edits require
  `editor-core` by, and what the build's core check holds the set's
  manifest to; none when it is not known. -/
  coreDirectory : Option String := none
  /-- The environment its link ran with, from `<executable>.build`. -/
  build : Array (String × String) := #[]
  /-- The Lean toolchain's directory, if one is known. -/
  sysroot : Option String := none
  /-- `<sysroot>/bin/lake`, when that file is there. -/
  lake : Option String := none
  /-- The user's data directory: where per-user editors are installed
  (`Editor/PackageSet/Layout.lean`); none for a host that has none. -/
  data : Option String := none
  /-- What the last reload read of the config directory as a package set:
  the one field the host sets again, after each reload, so the package
  commands edit the lakefile as it was read
  (the package `package-set`, `packages/package-set/`). -/
  facts : Facts := {}
  deriving DecidableEq, Repr, BEq, Inhabited

/-- The record `<name>.<kind>` of the executable at `appPath`: beside it;
in an app bundle, in `<bundle>/Contents/Resources`, where `codesign` lets
a file that is not code be. -/
def recordPathOf (appPath : String) (kind : String) : String :=
  let path := System.FilePath.mk appPath
  match path.parent, path.parent.bind (·.parent), path.fileName with
  | some macOS, some contents, some name =>
    if macOS.fileName == some "MacOS" && contents.fileName == some "Contents" then
      (contents / "Resources" / s!"{name}.{kind}").toString
    else s!"{appPath}.{kind}"
  | _, _, _ => s!"{appPath}.{kind}"

/-- The record of the core's identity of the executable at `appPath`:
beside it, `<executable>.core`, where the package-set build writes it; in
an app bundle, `<bundle>/Contents/Resources/<name>.core`, where
the `stage-bundle` binary puts it, since `codesign` refuses a file in
`Contents/MacOS` that is not code. The launcher reads it by the same rule
(`crates/editor-launch/src/editors.rs`, `core_record`). -/
def coreRecordPath (appPath : String) : String :=
  recordPathOf appPath "core"

/-- The record of the build environment of the executable at `appPath`
(`recordPathOf`): beside it, `<executable>.build`, where the package-set
build writes it; in an app bundle, `<bundle>/Contents/Resources/<name>.build`,
which the `stage-bundle` binary writes without `LEAN_CC`, so a build the app
runs compiles with the bundled toolchain's own `clang`. -/
def buildRecordPath (appPath : String) : String :=
  recordPathOf appPath "build"

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
the set's Lake name and directory, when it knows them), the directory of
the core it is linked from (`coreDirectory`, when it knows one), its config
directory `config`, its toolchain directory `sysroot` and its data
directory `data`. -/
def «at» {m : Type → Type} [Monad m] (appPath : String) (config : String)
    (set : Option (String × String)) (coreDirectory : Option String) (sysroot data : Option String)
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
  return { executable := appPath, config, fingerprint, core, coreDirectory, build, sysroot, lake,
           data }

/-- The shipped set's Lake name, as the running editor knows it: its
fingerprint's. -/
def Running.setName (running : Running) : Option String :=
  running.fingerprint.bind (·.set)

end Editor.PackageSet

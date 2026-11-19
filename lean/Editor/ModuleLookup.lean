/-!
# Where the editor's Lean modules are

Config is elaborated on modules imported from two directories
(`Editor/Config/Elaborate.lean`): the Lean toolchain's, a sysroot whose
modules are under its `lib/lean`, and the directory of the `.olean` files
of the modules config is elaborated on, the config base's, which are the
core's. This module says which two directories an executable uses, from its
own path, the directories its command line gave, and what the build
recorded for it. It reads nothing itself, so `model-test` pins it
(`ModelTest.moduleLookupChecks`).

- **In a bundle**, an executable at `<bundle>/Contents/MacOS/<name>`, the
  toolchain is `<bundle>/Contents/Resources/lean/toolchain` and the editor's
  `.olean` files are in `<bundle>/Contents/Resources/lean/editor`. The
  bundle is known by that layout alone, not by a `.app` suffix, so a renamed
  or copied bundle still finds its modules; the rule is the same on every
  platform.
- **Outside one** there is no toolchain unless one is given, and the
  `.olean` files are where the build that linked the executable recorded
  them: the first directory of its record. With no record there is no
  `.olean` directory unless one is given. None is guessed from where the
  executable is.
- **A directory given on the command line** is used in place of either,
  each on its own, wherever the executable is: tests and development runs
  give both.

## The record

An editor is linked from a package set (`docs/design/packages.md`, "The
package set and its build"), into the set's build directory, and each Lake
package's modules are built in that package's own: the core's in
`lean/.lake/build/lib/lean`, a package's in its own `.lake/build/lib/lean`.
So no directory relative to the executable holds them. The build writes
where they are beside the executable it links, in `<executable>.oleans`
(`recordPath`): one directory a line, absolute, the core's first, then that
of each other package of the set that holds a Lean library, in the order
the set's packages register.

The elaborator searches one directory beside the toolchain's, and the
config base's modules are all the core's, so the first line is the one
used here (`resolve`). The others are recorded for when the base holds a
package's modules and the elaborator searches several (the packages
roadmap's phase 6 moves the compile mode, which the base imports, out of
the core). The default set's record has a second line already, the
directory of the shipped themes' package (`packages/shipped-themes/`), which
is not searched and need not be: config names a theme by its name, and the
themes are registered by linked code.

The record is no part of a bundle: the bundle's layout is the rule there,
and the record names directories of the machine that built it.

Nothing is read from the environment: `LEAN_PATH` and every other variable
are ignored, as the elaborator ignores them. The executable's path is read
at each edge, from `IO.appPath`: the window mode's `main`
(`Editor/Window/Real.lean`), which also reads the record through
`recorded`, and the headless mode's (`Editor/Headless.lean`), which takes
both directories from its command line outside a bundle and so reads no
record.
-/

namespace Editor.ModuleLookup

/-- The directories a command line gave explicitly. -/
structure Given where
  /-- The Lean toolchain's directory, if one was given. -/
  sysroot : Option String := none
  /-- The directory of the editor's `.olean` files, if one was given. -/
  oleans : Option String := none

/-- The directories config's modules are imported from. -/
structure Directories where
  /-- The Lean toolchain's directory; none when there is none to use. -/
  sysroot : Option String
  /-- The directory of the editor's `.olean` files; none when there is none
  to use: outside a bundle, with none given and none recorded. -/
  oleans : Option String
  deriving DecidableEq, Repr

/-- The bundle an executable at `appPath` is in: the directory two above its
own when its directory is named `MacOS` and that one's parent `Contents`;
none otherwise. -/
def bundle? (appPath : String) : Option System.FilePath := do
  let macOS ← (System.FilePath.mk appPath).parent
  let contents ← macOS.parent
  guard (macOS.fileName == some "MacOS" && contents.fileName == some "Contents")
  contents.parent

/-- The file the package-set build writes beside an executable it links, to
say where the `.olean` files of the set's packages are ("The record", in
the module docs): `<executable>.oleans`. -/
def recordPath (appPath : String) : System.FilePath :=
  appPath ++ ".oleans"

/-- The directories a record's text names: its lines that are not empty, in
order. -/
def recordedIn (text : String) : List String :=
  (text.splitOn "\n").filter (!·.isEmpty)

/-- The directories recorded for the executable at `appPath`, read through
`readFile`, the port, which answers a file's text or none when it cannot be
read: those of the file `recordPath` names, and none when there is no such
file. In a bundle nothing is read: the bundle's layout is the rule there.
The edge passes the real file read, and the model tests a fake. -/
def recorded {m : Type → Type} [Monad m] (appPath : String)
    (readFile : System.FilePath → m (Option String)) : m (List String) := do
  if (bundle? appPath).isSome then
    return []
  return ((← readFile (recordPath appPath)).map recordedIn).getD []

/-- The directories for an executable at `appPath`, given `explicit` and
the directories `recorded` for it by the build that linked it: the
bundle's in a bundle; outside one, no toolchain and the first recorded
directory, or none when nothing was recorded; and each directory `explicit`
holds in place of its own. -/
def resolve (appPath : String) (explicit : Given) (recorded : List String := []) : Directories :=
  match bundle? appPath with
  | some bundle =>
    let resources := bundle / "Contents" / "Resources" / "lean"
    { sysroot := explicit.sysroot <|> some (resources / "toolchain").toString
      oleans := explicit.oleans <|> some (resources / "editor").toString }
  | none => { sysroot := explicit.sysroot, oleans := explicit.oleans <|> recorded.head? }

end Editor.ModuleLookup

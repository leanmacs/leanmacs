/-!
# Where the editor's Lean modules are

Config is elaborated on modules imported from the Lean toolchain's
directory, a sysroot whose modules are under its `lib/lean`, and from the
directories of the `.olean` files of the modules config is elaborated on,
the config base's (`Editor/Config/Elaborate.lean`): the core's, and those
of each package of the set the base names (`Editor/Main.lean`, "The
base"). This module says which directories an executable uses, from its
own path, the directories its command line gave, and what the build
recorded for it. It reads nothing itself, so `model-test` pins it
(`ModelTest.moduleLookupChecks`).

- **In a bundle**, an executable at `<bundle>/Contents/MacOS/<name>`, the
  toolchain is `<bundle>/Contents/Resources/lean/toolchain` and the editor's
  `.olean` files are in `<bundle>/Contents/Resources/lean/editor`, one
  directory that holds every module of the base, the packages' among them.
  The bundle is known by that layout alone, not by a `.app` suffix, so a
  renamed or copied bundle still finds its modules; the rule is the same on
  every platform.
- **Outside one** there is no toolchain unless one is given, and the
  `.olean` files are where the build that linked the executable recorded
  them: every directory of its record, in order. With no record there is no
  `.olean` directory unless one is given. None is guessed from where the
  executable is.
- **A directory given on the command line** is a search path: one
  directory, or several joined with `:`, searched in order (`searchPath`).
  The toolchain's is used in place of the bundle's. The `.olean`
  directories given are used in place of the bundle's in a bundle, and
  outside one they are searched before the recorded ones, which are still
  added: tests and development runs give the core's directory alone, and
  the modules of the set's packages are found through the record. An
  executable with no record, a staged or relinked one, is given every
  directory.

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

The elaborator searches all of them (`resolve`): the base config is
elaborated on holds the entry module of each package of the set, whose
`.olean` files are in that package's directory. The default set's record
names the core's directory, then that of each default package
(`packages/`).

The record is no part of a bundle: the bundle's layout is the rule there,
and the record names directories of the machine that built it.

Nothing is read from the environment: `LEAN_PATH` and every other variable
are ignored, as the elaborator ignores them. The executable's path is read
at each edge, from `IO.appPath`, with the record through `recorded`: the
window mode's `main` (`Editor/Window/Real.lean`) and the headless mode's
(`Editor/Headless.lean`).
-/

namespace Editor.ModuleLookup

/-- The directories a command line gave explicitly. -/
structure Given where
  /-- The Lean toolchain's directory, if one was given. -/
  sysroot : Option String := none
  /-- The directories of the editor's `.olean` files, as given: one, or
  several joined with `:` (`searchPath`); none when none was given. -/
  oleans : Option String := none

/-- The directories config's modules are imported from. -/
structure Directories where
  /-- The Lean toolchain's directory; none when there is none to use. -/
  sysroot : Option String
  /-- The directories of the editor's `.olean` files, in the order they are
  searched; empty when there is none to use: outside a bundle, with none
  given and none recorded. -/
  oleans : List String
  deriving DecidableEq, Repr

/-- The directories a directory argument names: one, or several joined
with `:`, in order. An empty part names none, so the empty text names no
directory. A directory whose own path holds a `:` cannot be given. -/
def searchPath (argument : String) : List String :=
  (argument.splitOn ":").filter (!·.isEmpty)

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
the directories `recorded` for it by the build that linked it. The
toolchain is the one given, else the bundle's in a bundle, else none. The
`.olean` directories are, in a bundle, the ones given (`searchPath`), else
the bundle's one; outside a bundle, the ones given and then every recorded
one, so none when nothing was given and nothing recorded. -/
def resolve (appPath : String) (explicit : Given) (recorded : List String := []) : Directories :=
  let given := (explicit.oleans.map searchPath).getD []
  match bundle? appPath with
  | some bundle =>
    let resources := bundle / "Contents" / "Resources" / "lean"
    { sysroot := explicit.sysroot <|> some (resources / "toolchain").toString
      oleans := if explicit.oleans.isSome then given else [(resources / "editor").toString] }
  | none => { sysroot := explicit.sysroot, oleans := given ++ recorded }

end Editor.ModuleLookup

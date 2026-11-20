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
the set's packages register. A relative line names a directory under the
executable's own (`recordedAt`): a per-user install of a set
(`docs/design/packages.md`, "User package sets") copies its modules into
`lib/lean` beside the executable and records that one line, so the
install's directory can be renamed into place.

The elaborator searches all of them (`resolve`): the base config is
elaborated on holds the entry module of each package of the set, whose
`.olean` files are in that package's directory. The default set's record
names the core's directory, then that of each default package
(`packages/`).

The record is no part of a bundle: the bundle's layout is the rule there,
and the record names directories of the machine that built it.

## The set

An editor also knows where the package set it was built from is, when that
directory is there (`setDirectory?`): the lakefile it generates for a
config directory requires the set by its directory
(`Editor/Config/LakePackage.lean`), so that Lean's language server, started
in the config directory, finds the modules config imports.

- **Outside a bundle** the build writes the set's directory beside the
  executable it links, in `<executable>.set` (`setRecordPath`): one line,
  absolute. An executable with no such record, a staged or relinked one,
  knows no set directory.
- **In a bundle** it is `<bundle>/Contents/Resources/lean/set`, by the
  bundle's layout, as the other two directories are. A bundle does not hold
  that directory yet: the app ships no package set to name, so an editor in
  a bundle knows none, and generates no lakefile.
- A directory that is not there is none, in either case.

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

/-- The directories a record's text names for the executable at `appPath`
(`recordedIn`), a relative line resolved against the executable's own
directory: a per-user install writes `lib/lean`, so its directory can be
renamed into place ("The record", in the module docs). An absolute line is
kept as it is. -/
def recordedAt (appPath : String) (text : String) : List String :=
  let directory := (System.FilePath.mk appPath).parent.getD "."
  (recordedIn text).map fun line =>
    if (System.FilePath.mk line).isAbsolute then line else (directory / line).toString

/-- The directories recorded for the executable at `appPath`, read through
`readFile`, the port, which answers a file's text or none when it cannot be
read: those of the file `recordPath` names (`recordedAt`), and none when
there is no such file. In a bundle nothing is read: the bundle's layout is
the rule there. The edge passes the real file read, and the model tests a
fake. -/
def recorded {m : Type → Type} [Monad m] (appPath : String)
    (readFile : System.FilePath → m (Option String)) : m (List String) := do
  if (bundle? appPath).isSome then
    return []
  return ((← readFile (recordPath appPath)).map (recordedAt appPath)).getD []

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

/-- The file the package-set build writes beside an executable it links, to
say where the package set it was built from is ("The set", in the module
docs): `<executable>.set`. -/
def setRecordPath (appPath : String) : System.FilePath :=
  appPath ++ ".set"

/-- The directory a set record's text names: its first line that is not
empty; none when it has none. -/
def setRecordedIn (text : String) : Option String :=
  ((text.splitOn "\n").filter (!·.isEmpty)).head?

/-- The directory of the package set the executable at `appPath` was built
from, when it is there: in a bundle, `Contents/Resources/lean/set`, and
outside one the directory the record `setRecordPath` names, read through
`readFile`, which answers a file's text or none when it cannot be read.
`isDirectory` says whether a path is a directory that is there: a
directory that is not is no set directory, so nothing is named that could
not be required. The edge passes the real reads, and the model tests
fakes. -/
def setDirectory? {m : Type → Type} [Monad m] (appPath : String)
    (readFile : System.FilePath → m (Option String)) (isDirectory : System.FilePath → m Bool) :
    m (Option String) := do
  let named ←
    match bundle? appPath with
    | some bundle =>
      pure (some (bundle / "Contents" / "Resources" / "lean" / "set").toString)
    | none =>
      pure ((← readFile (setRecordPath appPath)).bind setRecordedIn)
  match named with
  | some directory =>
    return if ← isDirectory directory then some directory else none
  | none =>
    return none

end Editor.ModuleLookup

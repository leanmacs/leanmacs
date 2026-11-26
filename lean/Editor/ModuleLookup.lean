import Editor.PackageSet.Fingerprint

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
  `.olean` files are in the directories the bundle's record names
  ("The bundle's record"); a bundle with no record has none. The bundle is known by that
  layout alone, not by a `.app` suffix, so a renamed or copied bundle still
  finds its modules; the rule is the same on every platform.
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

The record beside an executable is never read in a bundle: it names
directories of the machine that built it.

## The bundle's record

A bundle's `.olean` directories are the lines of
`<bundle>/Contents/Resources/editor.oleans` (`bundleRecordPath`), each
relative line resolved against `<bundle>/Contents/Resources` and an
absolute one kept (`recordedInBundle`), in order: the staged core's, then
each staged default package's (the `stage-bundle` binary;
`docs/design/lean-runtime.md`, "Build"). So the bundle ships each package's
modules once, in that package's own build directory, where a user's
package-set build reads them too. It is in `Contents/Resources`, beside
the core's record, because `codesign` refuses a file in `Contents/MacOS`
that is not code.

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
  bundle's layout, as the toolchain is: the default set the app ships,
  which the `stage-bundle` binary stages there, so the lakefile an editor in
  the app generates names it.
- A directory that is not there is none, in either case.

## The core

An editor also knows where the core it is linked from is, when that
directory is there (`coreDirectory?`), by the same rule as the set's: the
lakefile it writes for a config directory requires `editor-core` at its
root by that directory (`Editor/Config/LakePackage.lean`,
`Editor/PackageSet/Edit.lean`), so the user's set links the running
editor's own core, whatever core a package names
(`docs/design/packages.md`, "A config directory requires the core and the
set").

- **Outside a bundle** the build writes the core's directory beside the
  executable it links, in `<executable>.coredir` (`coreDirRecordPath`):
  one line, absolute, the directory of the `editor-core` package Lake
  linked, as Lake spells it. A per-user install copies it as
  `editor.coredir`, so a per-user editor knows the core it was built
  against. An executable with no such record knows no core directory.
- **In a bundle** it is `<bundle>/Contents/Resources/lean/lean`, by the
  bundle's layout: the core the app ships.
- The directory is normalised lexically (`PackageSet.normalise`), and one
  that is not there is none, in either case.

## The grammars

A package set's Lake packages that carry the keyword `editor-grammars` ship
grammar files under their `grammars/` directory (`docs/design/packages.md`,
"A package's grammars"), and a package's grammar declarations name paths
relative to it. Where each such directory is staged beside an executable is
a record of lines `<lake name><TAB><directory>` (`grammarsRecordedIn`), read
like the `.olean` record (`grammarDirectories`):

- **Outside a bundle**, `<executable>.grammars` (`grammarsRecordPath`), a
  relative line resolved against the executable's directory: the set's
  build writes absolute lines naming `<set>/.lake/build/grammars/<lake>`,
  and a per-user install copies each directory to `grammars/<lake>` beside
  its executable and writes relative lines, so the install still renames
  into place.
- **In a bundle**, `<bundle>/Contents/Resources/editor.grammars`
  (`bundleGrammarsRecordPath`), relative lines resolved against
  `Contents/Resources`: the `stage-bundle` binary writes
  `lean/set/<rel>/grammars`, the package's own copy in the bundle's staged
  set. The record beside the executable is never read in a bundle.

No record, or no line for a Lake package, is no directory: a package of it
that declares grammars is refused (`Editor/Config/Packages.lean`, "A
package's grammars").

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

/-- The bundle's record of its `.olean` directories ("The bundle's record",
in the module docs): `<bundle>/Contents/Resources/editor.oleans`. -/
def bundleRecordPath (bundle : System.FilePath) : System.FilePath :=
  bundle / "Contents" / "Resources" / "editor.oleans"

/-- The directories the text of the record of the bundle `bundle` names
(`recordedIn`), a relative line resolved against the bundle's
`Contents/Resources` and an absolute line kept as it is. -/
def recordedInBundle (bundle : System.FilePath) (text : String) : List String :=
  let resources := bundle / "Contents" / "Resources"
  (recordedIn text).map fun line =>
    if (System.FilePath.mk line).isAbsolute then line else (resources / line).toString

/-- The directories recorded for the executable at `appPath`, read through
`readFile`, the port, which answers a file's text or none when it cannot be
read: in a bundle, those of the bundle's record (`bundleRecordPath`,
`recordedInBundle`); outside one, those of the file `recordPath` names
(`recordedAt`); none when there is no such file. The edge passes the real
file read, and the model tests a fake. -/
def recorded {m : Type → Type} [Monad m] (appPath : String)
    (readFile : System.FilePath → m (Option String)) : m (List String) := do
  match bundle? appPath with
  | some bundle =>
    return ((← readFile (bundleRecordPath bundle)).map (recordedInBundle bundle)).getD []
  | none =>
    return ((← readFile (recordPath appPath)).map (recordedAt appPath)).getD []

/-- The directories for an executable at `appPath`, given `explicit`, the
directories `recorded` for it (`recorded`), and the shipped
default it was launched with (`--shipped`), if any: outside a bundle with
no toolchain given, a shipped default in a bundle lends that bundle's
toolchain, so a per-user editor the app's launcher started loads config. The
toolchain is the one given, else the bundle's in a bundle, else none. The
`.olean` directories are, in a bundle, the ones given (`searchPath`), else
the ones its record names, so none with no record; outside a bundle, the ones given and then every recorded
one, so none when nothing was given and nothing recorded. -/
def resolve (appPath : String) (explicit : Given) (recorded : List String := [])
    (shipped : Option String := none) : Directories :=
  let given := (explicit.oleans.map searchPath).getD []
  match bundle? appPath with
  | some bundle =>
    let resources := bundle / "Contents" / "Resources" / "lean"
    { sysroot := explicit.sysroot <|> some (resources / "toolchain").toString
      oleans := if explicit.oleans.isSome then given else recorded }
  | none =>
    -- A per-user editor the app's launcher started: the shipped default's
    -- bundle holds the toolchain.
    let shippedToolchain :=
      ((shipped.bind bundle?).map fun bundle =>
        (bundle / "Contents" / "Resources" / "lean" / "toolchain").toString)
    { sysroot := explicit.sysroot <|> shippedToolchain, oleans := given ++ recorded }

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

/-- The file the package-set build writes beside an executable it links, to
say where the core it is linked from is ("The core", in the module docs):
`<executable>.coredir`. -/
def coreDirRecordPath (appPath : String) : System.FilePath :=
  appPath ++ ".coredir"

/-- The directory of the core the executable at `appPath` is linked from,
when it is there ("The core", in the module docs): in a bundle,
`Contents/Resources/lean/lean`, and outside one the first line of the
record `coreDirRecordPath`, read through `readFile`, normalised lexically.
`isDirectory` says whether a path is a directory that is there. The edge
passes the real reads, and the model tests fakes. -/
def coreDirectory? {m : Type → Type} [Monad m] (appPath : String)
    (readFile : System.FilePath → m (Option String)) (isDirectory : System.FilePath → m Bool) :
    m (Option String) := do
  let named ←
    match bundle? appPath with
    | some bundle =>
      pure (some (bundle / "Contents" / "Resources" / "lean" / "lean").toString)
    | none =>
      pure
          (((← readFile (coreDirRecordPath appPath)).bind setRecordedIn).map
            (PackageSet.normalise "/"))
  match named with
  | some directory =>
    return if ← isDirectory directory then some directory else none
  | none =>
    return none

/-- The file the package-set build writes beside an executable it links, to
say where the grammars directory of each Lake package of the set that ships
grammars is staged ("The grammars", in the module docs):
`<executable>.grammars`. -/
def grammarsRecordPath (appPath : String) : System.FilePath :=
  appPath ++ ".grammars"

/-- The bundle's record of its staged grammars directories ("The grammars",
in the module docs): `<bundle>/Contents/Resources/editor.grammars`. -/
def bundleGrammarsRecordPath (bundle : System.FilePath) : System.FilePath :=
  bundle / "Contents" / "Resources" / "editor.grammars"

/-- What the text of a grammars record names: each line that holds a tab,
a Lake package's name before it and its directory after it, a relative
directory resolved against `base` and an absolute one kept, in order; a
blank line and a line with no tab are skipped. -/
def grammarsRecordedIn (base : System.FilePath) (text : String) : List (String × System.FilePath) :=
  (text.splitOn "\n").filterMap fun line =>
    match line.splitOn "\t" with
    | lake :: directory :: rest =>
      let directory : System.FilePath := "\t".intercalate (directory :: rest)
      some (lake, if directory.isAbsolute then directory else base / directory)
    | _ => none

/-- The staged grammars directory of each Lake package of the set the
executable at `appPath` was built from that ships grammars, read through
`readFile`, the port, which answers a file's text or none when it cannot be
read: in a bundle, those of the bundle's record (`bundleGrammarsRecordPath`)
resolved against its `Contents/Resources`; outside one, those of the file
`grammarsRecordPath` names resolved against the executable's directory;
none when there is no such file. The edges pass the real read, and the
model tests a fake. -/
def grammarDirectories {m : Type → Type} [Monad m] (appPath : String)
    (readFile : System.FilePath → m (Option String)) : m (List (String × System.FilePath)) := do
  match bundle? appPath with
  | some bundle =>
    return ((← readFile (bundleGrammarsRecordPath bundle)).map
            (grammarsRecordedIn (bundle / "Contents" / "Resources"))).getD
        []
  | none =>
    let directory := (System.FilePath.mk appPath).parent.getD "."
    return ((← readFile (grammarsRecordPath appPath)).map (grammarsRecordedIn directory)).getD []

end Editor.ModuleLookup

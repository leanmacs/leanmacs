/-!
# Where the editor's Lean modules are

Config is elaborated on modules imported from two directories
(`Editor/Config/Elaborate.lean`): the Lean toolchain's, a sysroot whose
modules are under its `lib/lean`, and the directory of the editor package's
`.olean` files. This module says which two directories an executable uses,
from its own path and the directories its command line gave. It reads
nothing itself, so `model-test` pins it (`ModelTest.moduleLookupChecks`).

- **In a bundle**, an executable at `<bundle>/Contents/MacOS/<name>`, the
  toolchain is `<bundle>/Contents/Resources/lean/toolchain` and the editor's
  `.olean` files are in `<bundle>/Contents/Resources/lean/editor`. The
  bundle is known by that layout alone, not by a `.app` suffix, so a renamed
  or copied bundle still finds its modules; the rule is the same on every
  platform.
- **Outside one** there is no toolchain unless one is given, and the
  `.olean` files are `<directory of the executable>/../lib/lean`, where
  Lake puts them in the build tree.
- **A directory given on the command line** is used in place of either,
  each on its own, wherever the executable is: tests and development runs
  give both.

Nothing is read from the environment: `LEAN_PATH` and every other variable
are ignored, as the elaborator ignores them. The executable's path is read
at each edge, from `IO.appPath`: the window mode's `main`
(`Editor/Window/Real.lean`) and the headless mode's (`Editor/Headless.lean`).
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
  /-- The directory of the editor's `.olean` files. -/
  oleans : String
  deriving DecidableEq, Repr

/-- The bundle an executable at `appPath` is in: the directory two above its
own when its directory is named `MacOS` and that one's parent `Contents`;
none otherwise. -/
def bundle? (appPath : String) : Option System.FilePath := do
  let macOS ← (System.FilePath.mk appPath).parent
  let contents ← macOS.parent
  guard (macOS.fileName == some "MacOS" && contents.fileName == some "Contents")
  contents.parent

/-- The directories for an executable at `appPath`, given `explicit`: the
bundle's in a bundle, no toolchain and `../lib/lean` outside one, and each
directory `explicit` holds in place of its own. -/
def resolve (appPath : String) (explicit : Given) : Directories :=
  match bundle? appPath with
  | some bundle =>
    let resources := bundle / "Contents" / "Resources" / "lean"
    { sysroot := explicit.sysroot <|> some (resources / "toolchain").toString
      oleans := explicit.oleans.getD (resources / "editor").toString }
  | none =>
    let executable := (System.FilePath.mk appPath).parent.getD "."
    { sysroot := explicit.sysroot
      oleans := explicit.oleans.getD (executable / ".." / "lib" / "lean").toString }

end Editor.ModuleLookup

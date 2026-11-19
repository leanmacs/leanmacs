import Editor.Config.ExactPath
import Editor.Config.Session

/-!
# The source port and the package ports, answered by a directory

The real adapter of `Config.Source` (`Editor/Config/Session.lean`), and
the file reads and writes the package ports are made of: a config is one
directory.

```
init.lean            the root
Config/Keys.lean     the config file whose module is Config.Keys
lakefile.toml        the directory as a Lake package
lean-toolchain
```

- **The root** is `init.lean`, directly in the directory, and its module
  is `init`. A directory with none has no root.
- **A config file** is read by its module name, from the path the name
  gives under the directory (`Config.pathOf`): `Config/Evil/Keys.lean` for
  `Config.Evil.Keys`. A name with no file is absent. A file under `Config/`
  that no file imports is never read.
- **A name is exact about case.** A file is found by listing each
  directory on its path and requiring an entry of exactly that name
  (`Editor/Config/ExactPath.lean`), not by asking whether the path exists:
  on a file system that ignores case, `Config/keys.lean` exists when
  `Config/Keys.lean` does. A name that is a file's but for case is
  misspelt, with the module that file is, and a file `Init.lean` is no
  root.
- **The stray files** are the `.lean` files directly in the directory
  other than the root, in the byte order of their names: what a config in
  the old form, byte-ordered chunks with no header, is made of. A
  directory is not one, whatever its name, and nothing below a
  subdirectory is.
- **A file of the package** (`read`) is read by its name, and is none when
  it is not there. **Creating one** (`create`) writes it only when it is
  not there: a file that is there is the user's, and is never overwritten.
- A directory that does not exist or cannot be read makes `root` and
  `stray` throw, and so does a file that cannot be read or is not UTF-8.
  The session core turns that into a rejected reload with a diagnostic.
- The error is one line that names the path:
  `cannot read the config directory <path>: <reason>`, or
  `cannot read the config file <path>: <reason>`. The core knows nothing of
  files, and a diagnostic is printed as the first line of its message, so
  the path has to be on it. Lean's own file errors put it on a second line.

The directory is an argument. Nothing is read from the environment or the
working directory.

`config-test` runs the checks of this adapter (`ConfigTest.directoryChecks`),
each in a temporary directory of its own.
-/

namespace Editor.Config.Directory

/-- The error that `what`, at `path`, cannot be read, as one line that names
the path. Lean's own file errors put the path on a second line, and a
diagnostic is printed as its first. -/
def unreadable (what : String) (path : System.FilePath) (reason : String) : IO.Error :=
  IO.userError s!"cannot read the config {what} {path}: {(reason.splitOn "\n").headD ""}"

/-- The text of the file at `path`. -/
def fileText (path : System.FilePath) : IO String := do
  let bytes ←
    try
      IO.FS.readBinFile path
    catch error =>
      throw (unreadable "file" path (toString error))
  let some text := String.fromUTF8? bytes | throw (unreadable "file" path "it is not UTF-8")
  return text

/-- Whether `path` is a file: it is there, and it is not a directory. -/
def isFile (path : System.FilePath) : IO Bool :=
  return (← path.pathExists) && !(← path.isDir)

/-- Throws that `directory` cannot be read unless it is a directory that is
there. -/
def demand (directory : System.FilePath) : IO Unit := do
  let isDirectory ←
    try
      discard <| directory.metadata
      directory.isDir
    catch error =>
      throw (unreadable "directory" directory (toString error))
  unless isDirectory do
    throw (unreadable "directory" directory "it is not a directory")

/-- The module name of the config file at the path `components` below the
config directory: `Config.Keys` for `Config`, `Keys.lean`. -/
def moduleAt (components : List String) : String :=
  let path := ".".intercalate components
  if path.endsWith ".lean" then (path.dropEnd 5).toString else path

/-- The source whose files are in `directory`: the root is `init.lean`, the
config file of a module is at the path its name gives (`Config.pathOf`),
and the stray files are the `.lean` files directly in the directory other
than the root, in the byte order of their names. A file is found by
exactly its name, whatever the file system makes of case
(`Editor/Config/ExactPath.lean`): a config file whose name differs from the
one asked for only in case is misspelt, and a root spelt otherwise than
`init.lean` is no root. A file that is not there is absent; a directory
that is not there, and a file that cannot be read or is not UTF-8, throw
one line that names the path. -/
def source (directory : System.FilePath) : Source :=
  let fileAt (module path : String) : IO (Lookup SourceFile) := do
    match ← ExactPath.find directory (path.splitOn "/") with
    | .absent =>
      return .absent
    | .spelled components =>
      return .misspelt (moduleAt components) ("/".intercalate components)
    | .exact =>
      unless ← isFile (directory / path) do
        return .absent
      return .found { module, path, text := ← fileText (directory / path) }
  {
    root := do
      demand directory
      match ← fileAt rootModule rootPath with
      | .found file =>
        return some file
      | _ =>
        return none,
    file := fun module => fileAt module (pathOf module),
    stray := do
      let entries ←
        try
          directory.readDir
        catch error =>
          throw (unreadable "directory" directory (toString error))
      let files ← entries.filterM fun entry => return !(← entry.path.isDir)
      let names : Array String :=
        (files.map (·.fileName)).filter fun name => name.endsWith ".lean" && name != rootPath
      -- `<` on strings compares code points, which is the order of their
      -- UTF-8 bytes.
      return names.qsort (· < ·) }

/-- The text of the file of `directory` called `name`, or none when there
is no such file: the read half of the directory as a Lake package
(`PackageFiles.read`). -/
def read (directory : System.FilePath) (name : String) : IO (Option String) := do
  unless ← isFile (directory / name) do
    return none
  return some (← fileText (directory / name))

/-- Creates the file of `directory` called `name` holding `text`, unless a
file of that name is there, which is left as it is: the write half of the
directory as a Lake package (`Generator.create`). The file is
opened to be created, never to be replaced, so one that appears in between
is not overwritten either. -/
def create (directory : System.FilePath) (name text : String) : IO Unit := do
  if ← (directory / name).pathExists then
    return
  let handle ← IO.FS.Handle.mk (directory / name) .writeNew
  handle.putStr text

end Editor.Config.Directory

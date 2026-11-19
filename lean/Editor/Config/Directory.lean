import Editor.Config.Modules
import Editor.Config.Session

/-!
# The source port, answered by a directory

The real adapter of `Config.Source` (`Editor/Config/Session.lean`): a config
is the `.lean` files directly in one directory.

- A chunk is a file whose name ends in `.lean`, named by its file name. A
  directory is not a chunk, whatever its name, and nothing below a
  subdirectory is read.
- The chunks are in the byte order of their names, so `10-keys.lean` comes
  before `20-setup.lean` on every machine, whatever order the file system
  lists them in.
- An empty directory is a config with no chunks.
- A directory that does not exist or cannot be read makes `chunks` throw, and
  so does a file that cannot be read or is not UTF-8. The session core turns
  that into a rejected reload with a diagnostic.
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

/-- The text of the chunk file at `path`. -/
def chunkText (path : System.FilePath) : IO String := do
  let bytes ←
    try
      IO.FS.readBinFile path
    catch error =>
      throw (unreadable "file" path (toString error))
  let some text := String.fromUTF8? bytes | throw (unreadable "file" path "it is not UTF-8")
  return text

/-- The source whose chunks are the `.lean` files directly in `directory`. -/
def source (directory : System.FilePath) : Source :=
  {
    chunks := do
      let entries ←
        try
          directory.readDir
        catch error =>
          throw (unreadable "directory" directory (toString error))
      let files ← entries.filterM fun entry => return !(← entry.path.isDir)
      let names : Array String := (files.map (·.fileName)).filter (·.endsWith ".lean")
      -- `<` on strings compares code points, which is the order of their
      -- UTF-8 bytes.
      (names.qsort (· < ·)).mapM fun (name : String) => do
          let text ← chunkText (directory / name)
          return { name, text } }

/-! ## Config as modules

What follows answers the ports of the session over modules
(`Editor/Config/Modules.lean`), which stands beside the chunk session
until the hosts are switched to it. -/

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

/-- The source of config as modules whose files are in `directory`: the
root is `init.lean`, the config file of a module is at the path its name
gives (`Modules.pathOf`), and the stray files are the `.lean` files
directly in the directory other than the root, in the byte order of their
names. A file that is not there is none; a directory that is not there, and
a file that cannot be read or is not UTF-8, throw one line that names the
path. -/
def modules (directory : System.FilePath) : Modules.Source :=
  let fileAt (module path : String) : IO (Option Modules.SourceFile) := do
    unless ← isFile (directory / path) do
      return none
    return some { module, path, text := ← chunkText (directory / path) }
  {
    root := do
      demand directory
      fileAt Modules.rootModule Modules.rootPath,
    file := fun module => fileAt module (Modules.pathOf module),
    stray := do
      let entries ←
        try
          directory.readDir
        catch error =>
          throw (unreadable "directory" directory (toString error))
      let files ← entries.filterM fun entry => return !(← entry.path.isDir)
      let names : Array String :=
        (files.map (·.fileName)).filter fun name =>
          name.endsWith ".lean" && name != Modules.rootPath
      -- `<` on strings compares code points, which is the order of their
      -- UTF-8 bytes.
      return names.qsort (· < ·) }

/-- The text of the file of `directory` called `name`, or none when there
is no such file: the read half of the directory as a Lake package
(`Modules.Package.read`). -/
def read (directory : System.FilePath) (name : String) : IO (Option String) := do
  unless ← isFile (directory / name) do
    return none
  return some (← chunkText (directory / name))

/-- Creates the file of `directory` called `name` holding `text`, unless a
file of that name is there, which is left as it is: the write half of the
directory as a Lake package (`Modules.Generator.create`). The file is
opened to be created, never to be replaced, so one that appears in between
is not overwritten either. -/
def create (directory : System.FilePath) (name text : String) : IO Unit := do
  if ← (directory / name).pathExists then
    return
  let handle ← IO.FS.Handle.mk (directory / name) .writeNew
  handle.putStr text

end Editor.Config.Directory

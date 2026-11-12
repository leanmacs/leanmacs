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

The directory is an argument. Nothing is read from the environment or the
working directory.

`config-test` runs the checks of this adapter (`ConfigTest.directoryChecks`),
each in a temporary directory of its own.
-/

namespace Editor.Config.Directory

/-- The source whose chunks are the `.lean` files directly in `directory`. -/
def source (directory : System.FilePath) : Source :=
  {
    chunks := do
      let entries ← directory.readDir
      let files ← entries.filterM fun entry => return !(← entry.path.isDir)
      let names : Array String := (files.map (·.fileName)).filter (·.endsWith ".lean")
      -- `<` on strings compares code points, which is the order of their
      -- UTF-8 bytes.
      (names.qsort (· < ·)).mapM fun (name : String) => do
          let text ← IO.FS.readFile (directory / name)
          return { name, text } }

end Editor.Config.Directory

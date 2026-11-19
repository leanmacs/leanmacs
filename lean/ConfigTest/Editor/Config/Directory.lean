import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import Editor.Config.Directory
import Editor.Config.Modules

/-!
# Config tests: `Editor/Config/Directory.lean`

The tests of `Editor/Config/Directory.lean`: `directoryChecks`. The root module
`ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- The checks of the directory source (`Editor/Config/Directory.lean`), each
in a fresh temporary directory of its own, which is removed with the check. -/
def directoryChecks (_ : Unit) : List Check :=
  [{ name := "the chunks of a directory are its .lean files, in the byte order of their names",
     run :=
       IO.FS.withTempDir fun directory => do
         writeFiles directory
             [("20-b.lean", "second"), ("a.lean", "fourth"), ("10-a.lean", "first"),
               ("B.lean", "third")]
         return (← chunksOf directory) ==
             #[("10-a.lean", "first"), ("20-b.lean", "second"), ("B.lean", "third"),
               ("a.lean", "fourth")] },
    { name := "other files, and directories whatever their names, are not chunks"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("chunk.lean", "kept"), ("notes.txt", "x"), ("old.lean.bak", "x"), ("lean", "x")]
          IO.FS.createDirAll (directory / "nested.lean")
          writeFiles (directory / "nested.lean") [("inner.lean", "x")]
          IO.FS.createDirAll (directory / "sub")
          writeFiles (directory / "sub") [("deeper.lean", "x")]
          return (← chunksOf directory) == #[("chunk.lean", "kept")] },
    { name :=
        "a directory that does not exist cannot be read: the source throws one line that names the directory"
      run :=
        IO.FS.withTempDir fun directory => do
          let absent := directory / "absent"
          try
            discard <| chunksOf absent
            return false
          catch error =>
            return namesOnOneLine (toString error) absent },
    { name :=
        "a chunk that is not UTF-8 cannot be read: the source throws one line that names the file"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory [("good.lean", "kept")]
          IO.FS.writeBinFile (directory / "bad.lean") notUtf8
          try
            discard <| chunksOf directory
            return false
          catch error =>
            return namesOnOneLine (toString error) (directory / "bad.lean") },
    { name := "an empty directory is a config with no chunks"
      run := IO.FS.withTempDir fun directory => return (← chunksOf directory).isEmpty }]

/-- Writes each of `files`, a path below `directory` and a text, making the
directories on the way. -/
def writeTree (directory : System.FilePath) (files : List (String × String)) : IO Unit :=
  for (path, text) in files do
    let file := directory / path
    if let some parent := file.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile file text

/-- The checks of the directory as a source of modules and as a Lake
package (`Editor/Config/Directory.lean`), each in a fresh temporary
directory of its own, which is removed with the check. -/
def moduleDirectoryChecks (_ : Unit) : List Check :=
  [{
      name :=
        "the root is init.lean in the directory, as the module init, and a directory with none has no root",
      run :=
        IO.FS.withTempDir fun directory => do
          let source := Config.Directory.modules directory
          let before ← source.root
          writeTree directory [("init.lean", "the root"), ("Config/init.lean", "not it")]
          return before.isNone &&
              (← source.root) ==
                some { module := "init", path := "init.lean", text := "the root" } },
    { name :=
        "a config file is read by its module name from the path under Config that the name gives, a nested one too, and a name with no file gives none"
      run :=
        IO.FS.withTempDir fun directory => do
          writeTree directory
              [("init.lean", ""), ("Config/Keys.lean", "keys"), ("Config/Evil/Keys.lean", "evil")]
          let source := Config.Directory.modules directory
          return (← source.file "Config.Keys") ==
                some { module := "Config.Keys", path := "Config/Keys.lean", text := "keys" } &&
              (← source.file "Config.Evil.Keys") ==
                some
                  { module := "Config.Evil.Keys", path := "Config/Evil/Keys.lean",
                    text := "evil" } &&
              (← source.file "Config.Missing").isNone &&
              (← source.file "Config.Evil").isNone },
    { name :=
        "the stray files are the .lean files directly in the directory other than the root, in the byte order of their names: no other file, no directory, and nothing below one"
      run :=
        IO.FS.withTempDir fun directory => do
          writeTree directory
              [("20-b.lean", "x"), ("a.lean", "x"), ("10-a.lean", "x"), ("B.lean", "x"),
                ("init.lean", "x"), ("notes.txt", "x"), ("old.lean.bak", "x"),
                ("Config/Keys.lean", "x"), ("nested.lean/inner.lean", "x")]
          return (← (Config.Directory.modules directory).stray) ==
              #["10-a.lean", "20-b.lean", "B.lean", "a.lean"] },
    { name :=
        "a directory that does not exist cannot be read: the root and the stray files each throw one line that names the directory"
      run :=
        IO.FS.withTempDir fun directory => do
          let absent := directory / "absent"
          let source := Config.Directory.modules absent
          let thrown (read : IO Unit) : IO Bool := do
            try
              read
              return false
            catch error =>
              return namesOnOneLine (toString error) absent
          return (← thrown (discard <| source.root)) && (← thrown (discard <| source.stray)) },
    { name :=
        "a root or a config file that is not UTF-8 cannot be read: the source throws one line that names the file"
      run :=
        IO.FS.withTempDir fun directory => do
          IO.FS.createDirAll (directory / "Config")
          IO.FS.writeBinFile (directory / "init.lean") notUtf8
          IO.FS.writeBinFile (directory / "Config" / "Keys.lean") notUtf8
          let source := Config.Directory.modules directory
          let thrown (read : IO Unit) (path : System.FilePath) : IO Bool := do
            try
              read
              return false
            catch error =>
              return namesOnOneLine (toString error) path
          return (← thrown (discard <| source.root) (directory / "init.lean")) &&
              (←
                thrown (discard <| source.file "Config.Keys")
                    (directory / "Config" / "Keys.lean")) },
    { name :=
        "a file of the directory is read by its name, and a name with no file, or that is a directory, gives none"
      run :=
        IO.FS.withTempDir fun directory => do
          writeTree directory [("lakefile.toml", "name = \"config\"\n"), ("Config/Keys.lean", "x")]
          return (← Config.Directory.read directory "lakefile.toml") ==
                some "name = \"config\"\n" &&
              (← Config.Directory.read directory "lean-toolchain").isNone &&
              (← Config.Directory.read directory "Config").isNone },
    { name :=
        "creating a file writes it when it is not there, and never overwrites: a file that is there keeps its text"
      run :=
        IO.FS.withTempDir fun directory => do
          Config.Directory.create directory "lean-toolchain" "the pin\n"
          let made ← IO.FS.readFile (directory / "lean-toolchain")
          writeTree directory [("lakefile.toml", "mine")]
          Config.Directory.create directory "lakefile.toml" "generated"
          Config.Directory.create directory "lean-toolchain" "another pin\n"
          return made == "the pin\n" &&
              (← IO.FS.readFile (directory / "lakefile.toml")) == "mine" &&
              (← IO.FS.readFile (directory / "lean-toolchain")) == "the pin\n" }]

end ConfigTest

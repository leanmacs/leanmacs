import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import Editor.Config.Directory
import Editor.Config.Elaborator.Model
import Editor.Config.Session
import Editor.InputScheme.Test

/-!
# Config tests: `Editor/Config/Directory.lean`

The tests of `Editor/Config/Directory.lean`: `directoryChecks`. The root module
`ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- The checks of the directory as a source of config files and as a Lake
package (`Editor/Config/Directory.lean`), each in a fresh temporary
directory of its own, which is removed with the check. -/
def directoryChecks (_ : Unit) : List Check :=
  [{
      name :=
        "the root is init.lean in the directory, as the module init, and a directory with none has no root",
      run :=
        IO.FS.withTempDir fun directory => do
          let source := Config.Directory.source directory
          let before ← source.root
          writeFiles directory [("init.lean", "the root"), ("Config/init.lean", "not it")]
          return before.isNone &&
              (← source.root) ==
                some { module := "init", path := "init.lean", text := "the root" } },
    { name :=
        "a config file is read by its module name from the path under Config that the name gives, a nested one too, and a name with no file is absent"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("init.lean", ""), ("Config/Keys.lean", "keys"), ("Config/Evil/Keys.lean", "evil")]
          let source := Config.Directory.source directory
          return (← source.file "Config.Keys") ==
                .found { module := "Config.Keys", path := "Config/Keys.lean", text := "keys" } &&
              (← source.file "Config.Evil.Keys") ==
                .found
                  { module := "Config.Evil.Keys", path := "Config/Evil/Keys.lean",
                    text := "evil" } &&
              (← source.file "Config.Missing") == .absent &&
              (← source.file "Config.Evil") == .absent },
    { name :=
        "on a file system that ignores case, a file is found by exactly its name: a config file asked for in another case is misspelt, with the module and the path the directory spells, though the path opens; a file Init.lean is no root (on a file system that does not ignore case, there is nothing to show, and the check passes)"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory [("Init.lean", "not the root"), ("Config/Evil/Keys.lean", "evil")]
          -- The file system ignores case when the path in other case opens.
          unless ← (directory / "config" / "evil" / "keys.lean").pathExists do
            return true
          let source := Config.Directory.source directory
          return (← source.root).isNone &&
              (← source.file "Config.Evil.keys") ==
                .misspelt "Config.Evil.Keys" "Config/Evil/Keys.lean" &&
              (← source.file "Config.evil.Keys") ==
                .misspelt "Config.Evil.Keys" "Config/Evil/Keys.lean" &&
              (← source.file "Config.Evil.Keys") ==
                .found
                  { module := "Config.Evil.Keys", path := "Config/Evil/Keys.lean",
                    text := "evil" } &&
              (← source.file "Config.Evil.Other") == .absent },
    { name :=
        "a directory that holds Init.lean and no init.lean is rejected as a misspelt root, naming Init.lean and init.lean, and not as the old form: the root is not found, and Init.lean is the stray file that names it, whether or not the file system ignores case"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory [("Init.lean", "import Editor\n")]
          let outcome ←
            Config.build TestScheme.scheme (Config.Elaborator.Model.elaborator)
                (Config.Directory.source directory) Config.PackageFiles.none none none #[]
          return outcome.built.isNone &&
              outcome.diagnostics == #[Config.misspeltRoot "Init.lean"] },
    { name :=
        "the stray files are the .lean files directly in the directory other than the root, in the byte order of their names: no other file, no directory, and nothing below one"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("20-b.lean", "x"), ("a.lean", "x"), ("10-a.lean", "x"), ("B.lean", "x"),
                ("init.lean", "x"), ("notes.txt", "x"), ("old.lean.bak", "x"),
                ("Config/Keys.lean", "x"), ("nested.lean/inner.lean", "x")]
          return (← (Config.Directory.source directory).stray) ==
              #["10-a.lean", "20-b.lean", "B.lean", "a.lean"] },
    { name :=
        "a directory that does not exist cannot be read: the root and the stray files each throw one line that names the directory"
      run :=
        IO.FS.withTempDir fun directory => do
          let absent := directory / "absent"
          let source := Config.Directory.source absent
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
          let source := Config.Directory.source directory
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
          writeFiles directory [("lakefile.toml", "name = \"config\"\n"), ("Config/Keys.lean", "x")]
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
          writeFiles directory [("lakefile.toml", "mine")]
          Config.Directory.create directory "lakefile.toml" "generated"
          Config.Directory.create directory "lean-toolchain" "another pin\n"
          return made == "the pin\n" &&
              (← IO.FS.readFile (directory / "lakefile.toml")) == "mine" &&
              (← IO.FS.readFile (directory / "lean-toolchain")) == "the pin\n" }]

end ConfigTest

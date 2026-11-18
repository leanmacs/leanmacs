import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts

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

end ConfigTest

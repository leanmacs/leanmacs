import Editor.File
import Editor.Invocation
import Editor.State

/-!
# The file jobs the loop starts

What the loop asks of a set's files feature, declared by the core so that
the loop names none of it (`Editor/Loop.lean`, "Files that changed on disk"
and "Auto-reload"), as the session journal's job is declared by the core
and registered by the feature that works it (`Editor/Restore.lean`,
`Restore.restoreJob`):

- **The open command's name** (`openFileCommand`, `open-file`), which the
  loop runs for the files a window asks to open (`Event.openFiles`) and the
  headless mode's `open`.
- **The check** (`checkJob`, `check-files`): the files the loop finds due a
  check after a publish (`Checked`), as the arguments the job is started
  with (`checkArguments`, read back by `checkOfArguments?`).
- **The follow** (`followJob`, `follow-file`): what auto-reload's
  reconciler starts for each file it follows (`FollowOrder`, its arguments
  and `stampArguments`).
- **What the loop says** when a first edit was refused because a buffer's
  file changed on disk (`changedOnDisk`) or is gone (`goneFromDisk`).

The loop's gate is the registry: it starts a check or a follow only where a
package registered the job under that name (`Loop.Registered.jobs`), so a
set without the files feature starts neither. The files feature
(`packages/files/Files.lean`) registers both jobs and defines its own names from
these, so its callers are unchanged.

Pinned by `ModelTest.fileJobChecks`; when the loop starts a check or a
follow by `ModelTest.loopChecks`, and what the jobs' commands do by
`ModelTest.fileCommandChecks`.
-/

namespace Editor.FileJobs

/-- The name the open command is registered under. -/
def openFileCommand : String :=
  "open-file"

/-- The name the job that checks files for a change on disk is registered
under. -/
def checkJob : String :=
  "check-files"

/-- One file a check looks at: the buffer, its file's path, and the stamp the
buffer recorded for it when the check was asked for. -/
structure Checked where
  /-- The buffer. -/
  buffer : BufferId
  /-- Its file's path. -/
  path : System.FilePath
  /-- The stamp the buffer recorded. -/
  stamp : File.Stamp
  deriving DecidableEq, Repr

/-- The files of a check as the arguments a job is started with: for each,
the buffer's number, the path and the stamp's seconds, nanoseconds and
size. -/
def checkArguments (files : Array Checked) : List Argument :=
  files.toList.flatMap fun file =>
    [.nat file.buffer.index, .str file.path.toString, .int file.stamp.seconds,
      .nat file.stamp.nanoseconds, .nat file.stamp.size]

/-- The files `arguments` are, if they are a check's (`checkArguments`). -/
def checkOfArguments? : List Argument → Option (Array Checked)
  | [] => some #[]
  | .nat buffer :: .str path :: .int seconds :: .nat nanoseconds :: .nat size :: rest =>
    (checkOfArguments? rest).map fun others =>
      #[{ buffer := ⟨buffer⟩, path, stamp := { seconds, nanoseconds, size } }] ++ others
  | _ => none

/-- What the echo area says when the first edit of the buffer of `path` was
refused because its file changed on disk: how to reload, and that the next
edit keeps the buffer's text. -/
def changedOnDisk (path : System.FilePath) : String :=
  s!"{path} changed on disk; :e reloads it, or edit again to keep this text"

/-- What the echo area says when the first edit of the buffer of `path` was
refused because its file is gone: `:e` cannot reload a file that is not
there, and `:w!` writes it again. -/
def goneFromDisk (path : System.FilePath) : String :=
  s!"{path} is gone from disk; :w! writes it again, or edit again to keep this text"

/-- The name the job that follows a file for auto-reload is registered
under. -/
def followJob : String :=
  "follow-file"

/-- What a follow job is started with: the buffer, its file's path, the stamp
the buffer recorded, which `markChanged` is guarded by, and the last stamp
found, which the job compares a stat with: `none` for a file that is gone.
The two differ exactly while the buffer is marked. -/
structure FollowOrder where
  /-- The buffer. -/
  buffer : BufferId
  /-- The file's path. -/
  path : System.FilePath
  /-- The stamp the buffer recorded. -/
  stamp : File.Stamp
  /-- The last stamp found, or `none` for a file that is gone. -/
  expected : Option File.Stamp
  deriving DecidableEq, Repr

/-- A stamp as three arguments. -/
def stampArguments (stamp : File.Stamp) : List Argument :=
  [.int stamp.seconds, .nat stamp.nanoseconds, .nat stamp.size]

/-- The order as arguments: the buffer's number, the path, the stamp, and the
expected stamp after `true`, or `false` alone for none. -/
def FollowOrder.arguments (order : FollowOrder) : List Argument :=
  [.nat order.buffer.index, .str order.path.toString] ++ stampArguments order.stamp ++
    match order.expected with
    | some expected => .bool true :: stampArguments expected
    | none => [.bool false]

/-- The order `arguments` are, if they are one (`FollowOrder.arguments`). -/
def FollowOrder.ofArguments? : List Argument → Option FollowOrder
  |
  [.nat buffer, .str path, .int seconds, .nat nanoseconds, .nat size, .bool true,
      .int expectedSeconds, .nat expectedNanoseconds, .nat expectedSize] =>
    some
      { buffer := ⟨buffer⟩, path, stamp := { seconds, nanoseconds, size }
        expected :=
          some
            { seconds := expectedSeconds, nanoseconds := expectedNanoseconds
              size := expectedSize } }
  | [.nat buffer, .str path, .int seconds, .nat nanoseconds, .nat size, .bool false] =>
    some { buffer := ⟨buffer⟩, path, stamp := { seconds, nanoseconds, size }, expected := none }
  | _ => none

end Editor.FileJobs

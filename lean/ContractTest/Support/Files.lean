import Editor.Fuzzy
import Editor.Job.Fake
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: support: Files

The library's file service: everything in a directory, and the rig a check of
the runner over that service works with (`FileRig`). Shared by several test
modules; it holds no checks of its own.
-/

namespace ContractTest

open Editor

/-- Everything in `directory`, each as its name and its bytes. A directory
there would be a surprise too: it is named, with no bytes. -/
def filesOf (directory : System.FilePath) : IO (Array (String × ByteArray)) := do
  let mut files := #[]
  for entry in ← directory.readDir do
    let bytes ←
      if ← entry.path.isDir then
        pure ByteArray.empty
      else
        IO.FS.readBinFile entry.path
    files := files.push (entry.fileName, bytes)
  return files

/-- What a check of the runner over the library's file service works with: a
text store whose table of snapshots is published, the file service over its
read half, and a fake clock a check parks a job on. The file waits are
completed by the process's pump, through `completions`; the clock's by the
check. Each check has its own, over the process's one table of waits. -/
structure FileRig where
  /-- The table of snapshots the store publishes. -/
  published : Snapshots
  /-- What the rig's jobs hold. -/
  held : Job.HeldSnapshots
  /-- The clock a job of the rig sleeps on, which only the check moves. -/
  clock : Job.FakeClock
  /-- The table of waits, the clock and the library's file service. -/
  services : Job.Services

/-- A rig over the table of waits `completions`, which the pump serves. -/
def FileRig.new (completions : Job.Completions) : BaseIO FileRig := do
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let clock ← Job.FakeClock.new completions
  return {
      published, held, clock
      services :=
        { completions, timers := clock.timers
          files := Job.realFiles completions published.reader held } }

end ContractTest

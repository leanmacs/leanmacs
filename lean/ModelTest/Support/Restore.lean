import Editor.Ex.Compiled
import Editor.Files.Compiled
import Editor.Restore.Compiled
import Editor.TabCommands.Compiled
import Editor.WindowCommands.Compiled
import Editor.Workspace.Compiled
import ModelTest.Support.WorkingSet

/-!
# Model tests: support: Restore

The session restore checks' world and driver: the working set checks' world
(evil's keys over the editor's models, the files of the checks under `/r`,
the file, buffer and workspace commands and jobs), with the `restore`
package's commands, mode and jobs, the ex commands, the window commands and
the tab commands, and the state directory `/state`. Session restore is a
feature still in the core, left for phase 6 to cut: it adopts a restored
file with the files feature (`Files.adopt`) and attaches its workspace
(`Workspace.attach`), and its jump goes to a file through files' visit, so
its driver has the files feature's jobs and the workspace's, before the
working set checks' fake's. Shared by the test modules of
`Editor/Restore.lean` and `Editor/Restore/Run.lean`; it holds no checks of
its own.
-/

namespace ModelTest

open Editor
open Editor.Restore
open WorkingSetTest

namespace RestoreTest

/-- The state directory of the checks. -/
def stateDirectory : System.FilePath :=
  "/state"

/-- A driver of the checks over `files`, its state directory `state`, each
step handed a log bound of `limit`, with `modes` registered beside the
restore package's and the config generation `generation`; `none` if making
the state was refused. -/
def restoreDriver (files : Option FileModel := none)
    (state : Option System.FilePath := some stateDirectory) (limit : Nat := Restore.bound)
    (modes : Array Mode := #[]) (generation : Nat := 0) : Option EvilDriver :=
  (driverWith
        (Restore.package.registered.commands ++ Ex.package.registered.commands ++
          WindowCommands.package.registered.commands ++
          TabCommands.package.registered.commands)
        (Restore.package.registered.modes ++ modes)
        (Restore.package.registered.jobs ++ Files.package.registered.jobs ++
          Workspace.package.registered.jobs)).map
    fun driver =>
    { driver with
      keys :=
        { driver.keys with
          journalBound := limit
          registered := { driver.keys.registered with generation } }
      loop := { driver.loop with state := { driver.loop.state with stateDirectory := state } }
      jobs := { driver.jobs with files := files.getD driver.jobs.files } }

/-- `driver` once its restore has run, as a host starts it first: the job
`restore` with the state directory, and everything it starts settled. -/
def begun (driver : EvilDriver) : EvilDriver :=
  drained (driver.started #[{ name := restoreJob, arguments := [.str stateDirectory.toString] }])

/-- A restored driver of the checks: `restoreDriver` with its restore run. -/
def restoredDriver (files : Option FileModel := none) (limit : Nat := Restore.bound)
    (modes : Array Mode := #[]) (generation : Nat := 0) : Option EvilDriver :=
  (restoreDriver files (limit := limit) (modes := modes) (generation := generation)).map begun

/-- The bytes of the file at `path` in `driver`'s world. -/
def bytesAt (driver : EvilDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- The paths of the files under `/state/session/journals/`, sorted. -/
def journalFiles (driver : EvilDriver) : Array String :=
  ((driver.jobs.files.files.map (·.path.toString)).filter
        (·.startsWith (journalsDirectory stateDirectory).toString)).qsort
    (· < ·)

/-- What the log of the journal of `buffer`'s generation `generation` of
the run `run` reads as. -/
def logOf (driver : EvilDriver) (run buffer generation : Nat) : Option Journal.Decoded := do
  let bytes ← bytesAt driver (logPath stateDirectory run buffer generation)
  return Journal.decode (File.decodeBytes bytes)

/-- The text the journal of `buffer`'s generation `generation` of the run
`run` restores: its base with its log replayed. -/
def journalText (driver : EvilDriver) (run buffer generation : Nat) : Option String := do
  let base ← bytesAt driver (basePath stateDirectory run buffer generation)
  let log ← logOf driver run buffer generation
  let program : TextM String := do
    let text ← createText (File.decodeBytes base)
    discard <| Journal.replay text log.records
    text.read
  (program.runModel {}).1.toOption

/-- The index of the run `run` in `driver`'s world, read. -/
def indexOf (driver : EvilDriver) (run : Nat) : Option Document := do
  let bytes ← bytesAt driver (indexPath stateDirectory run)
  (Document.read (indexName run) (File.decodeBytes bytes)).document

/-- The text of the buffer called `name`. -/
def textNamed (driver : EvilDriver) (name : String) : Option String := do
  let id ← driver.loop.state.findBuffer name
  let buffer ← driver.loop.state.buffer? id
  ((buffer.text.read).runModel driver.model.texts).1.toOption

/-- The buffer called `name`. -/
def bufferNamed (driver : EvilDriver) (name : String) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- A fresh driver over the world `driver` left, as after an abort and a
start: a new state over the same files, restored. -/
def restarted (driver : EvilDriver) (modes : Array Mode := #[]) (generation : Nat := 0)
    (change : FileModel → FileModel := id) : Option EvilDriver :=
  restoredDriver (some (change driver.jobs.files)) (modes := modes) (generation := generation)

/-- How many jobs called `name` are started and not delivered. -/
def pendingNamed (driver : EvilDriver) (name : String) : Nat :=
  (driver.pending.filter (·.name == name)).size

end RestoreTest

end ModelTest
